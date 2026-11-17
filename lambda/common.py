"""Shared configuration and storage for the IT Helpdesk chat AI Lambdas.

Three Lambda functions are deployed from this one package:

* ``bot.lambda_handler``    - fulfillment code hook of the Amazon Lex V2 bot that the Connect chat flow
  runs in its "Get customer input" block. Drives the whole conversation and returns Connect interactive
  messages (ListPicker / Panel) as Lex ``CustomPayload`` messages.
* ``analyze.lambda_handler`` - invoked by the chat flow in Asynchronous execution mode (up to 60 s): reads the
  uploaded image and calls the Bedrock multimodal model; the flow then re-enters the bot with the result.
* ``stream.lambda_handler`` - two entry points in one function:
    - invoked by the chat flow (Invoke AWS Lambda function) to call StartContactStreaming, so every chat
      message is published to the SNS topic;
    - subscribed to that SNS topic: records each file the CUSTOMER attaches (contact id -> attachment id),
      so the bot can find the uploaded screenshot and send it to a Bedrock multimodal model.

Storage is one DynamoDB table (pk / sk). Set ``CHAT_LOCAL=1`` to use an in-memory twin for local runs.
"""
import json
import logging
import os
import re
import time
from datetime import datetime, timezone

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
TABLE_NAME = os.environ.get("TABLE_NAME", "ith-chat-ai")
INSTANCE_ID = os.environ.get("INSTANCE_ID", "")
STREAM_TOPIC_ARN = os.environ.get("STREAM_TOPIC_ARN", "")
ATTACHMENTS_BUCKET = os.environ.get("ATTACHMENTS_BUCKET", "")
ATTACHMENTS_PREFIX = os.environ.get("ATTACHMENTS_PREFIX", "").strip("/")
VISION_MODEL_ID = os.environ.get("VISION_MODEL_ID", "us.anthropic.claude-sonnet-4-6")
TEXT_MODEL_ID = os.environ.get("TEXT_MODEL_ID", VISION_MODEL_ID)
COMPANY_NAME = os.environ.get("COMPANY_NAME", "Example Corp")
# Official sign-in domains. A screenshot of a sign-in page on any other domain is treated as possible phishing.
TRUSTED_DOMAINS = [d.strip().lower().lstrip(".") for d in
                   os.environ.get("TRUSTED_DOMAINS", "intranet.example.com,login.example.com,login.microsoftonline.com").split(",")
                   if d.strip()]
RESET_LINK_MINUTES = int(os.environ.get("RESET_LINK_MINUTES", "15"))
MAX_VERIFY_FAILS = int(os.environ.get("MAX_VERIFY_FAILS", "3"))          # per chat
MAX_VERIFY_FAILS_PER_HOUR = int(os.environ.get("MAX_VERIFY_FAILS_PER_HOUR", "5"))  # per employee, across chats
ATTACHMENT_TTL_SECONDS = 2 * 24 * 3600
LOCAL_MODE = os.environ.get("CHAT_LOCAL", "") == "1"


def now_utc():
    return datetime.now(timezone.utc)


def iso_now():
    return now_utc().isoformat(timespec="seconds")


def log(event, **kw):
    LOGGER.info(json.dumps({"event": event, **kw}, default=str, ensure_ascii=False))


# ---------------------------------------------------------------- clients (lazy, so local runs need no AWS)
_CLIENTS = {}


def client(name, **kw):
    if name not in _CLIENTS:
        import boto3
        from botocore.config import Config
        cfg = kw.pop("config", None) or Config(retries={"max_attempts": 2, "mode": "standard"})
        _CLIENTS[name] = boto3.client(name, config=cfg, **kw)
    return _CLIENTS[name]


# ---------------------------------------------------------------- DynamoDB single table (+ in-memory twin)
class _MemTable:
    def __init__(self):
        self.items = {}

    def put_item(self, Item, **_):
        self.items[(Item["pk"], Item["sk"])] = dict(Item)

    def get_item(self, Key, **_):
        it = self.items.get((Key["pk"], Key["sk"]))
        return {"Item": dict(it)} if it else {}

    def query_pk(self, pk, newest_first=True, limit=20):
        rows = sorted((v for (p, _), v in self.items.items() if p == pk), key=lambda r: r["sk"], reverse=newest_first)
        return rows[:limit]

    def delete_item(self, Key, **_):
        self.items.pop((Key["pk"], Key["sk"]), None)


_MEM = _MemTable()


def _table():
    if LOCAL_MODE:
        return _MEM
    import boto3
    if "table" not in _CLIENTS:
        _CLIENTS["table"] = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _CLIENTS["table"]


def _clean(v):  # DynamoDB returns Decimal for numbers (also nested); the code only stores ints
    if isinstance(v, dict):
        return {k: _clean(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_clean(x) for x in v]
    if type(v).__name__ == "Decimal":
        return int(v)
    return v


def db_put(item):
    _table().put_item(Item=item)


def db_get(pk, sk):
    it = _table().get_item(Key={"pk": pk, "sk": sk}).get("Item")
    return _clean(it) if it else None


def db_query(pk, newest_first=True, limit=20):
    t = _table()
    if LOCAL_MODE:
        return [_clean(r) for r in t.query_pk(pk, newest_first, limit)]
    from boto3.dynamodb.conditions import Key
    r = t.query(KeyConditionExpression=Key("pk").eq(pk), ScanIndexForward=not newest_first, Limit=limit)
    return [_clean(x) for x in r.get("Items", [])]


def db_delete(pk, sk):
    _table().delete_item(Key={"pk": pk, "sk": sk})


def save_session(contact_id, attrs):
    """Bot state saved before the bot hands off to the flow's asynchronous analysis (restored on re-entry)."""
    db_put({"pk": f"SESSION#{contact_id}", "sk": "STATE", "attrs": {k: str(v) for k, v in attrs.items()},
            "ttl": epoch() + 86400})


def load_session(contact_id):
    it = db_get(f"SESSION#{contact_id}", "STATE") if contact_id else None
    return dict(it.get("attrs") or {}) if it else None


def load_analysis(contact_id):
    it = db_get(f"ANALYSIS#{contact_id}", "LATEST") if contact_id else None
    return it.get("result") if it else None


def load_seed_users():
    with open(os.path.join(DATA_DIR, "seed_users.json"), encoding="utf-8") as f:
        return json.load(f)["users"]


def seed_local_directory():
    """Local runs only: load the mock directory into the in-memory table."""
    for u in load_seed_users():
        db_put({"pk": f"USER#{u['employee_id']}", "sk": "PROFILE", **u})


# ---------------------------------------------------------------- small text helpers
def norm(text):
    t = (text or "").lower().replace("\u2019", "'").replace("\u2018", "'")
    t = re.sub(r"[^a-z0-9' &/]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def mask_email(addr):
    if not addr or "@" not in addr:
        return "your registered personal email"
    local, domain = addr.split("@", 1)
    return f"{local[0]}{'*' * max(len(local) - 1, 3)}@{domain}"


def epoch():
    return int(time.time())
