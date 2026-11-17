"""Find and read the file a customer attached in the chat.

A Lex bot only receives text, and the Connect Participant API only lets the chat participants themselves
download attachments. So:
  1. the chat flow starts contact streaming (StartContactStreaming -> SNS topic);
  2. stream.py records every CUSTOMER attachment message as  pk=ATTACH#<contactId>, sk=<time>#<attachmentId>;
  3. this module reads the newest record and loads the file from the instance's ATTACHMENTS S3 storage.
     Chat attachments are stored as  <prefix>/chat/YYYY/MM/DD/<attachmentId>_<timestamp>.<ext>.
"""
import time
from datetime import datetime, timedelta, timezone

from common import ATTACHMENTS_BUCKET, ATTACHMENTS_PREFIX, LOCAL_MODE, client, db_put, db_query, epoch, log, ATTACHMENT_TTL_SECONDS

LOCAL_FILES = {}  # local runs: attachment id -> (bytes, content type)


def record_attachment(contact_id, attachment, absolute_time):
    db_put({"pk": f"ATTACH#{contact_id}", "sk": f"{absolute_time}#{attachment['AttachmentId']}",
            "attachment_id": attachment["AttachmentId"], "file_name": attachment.get("AttachmentName", ""),
            "content_type": attachment.get("ContentType", ""), "status": attachment.get("Status", ""),
            "absolute_time": absolute_time, "ttl": epoch() + ATTACHMENT_TTL_SECONDS})


def newest_attachment(contact_ids, exclude_id="", wait_seconds=4.0):
    """Newest customer attachment of any of the contact ids that is not exclude_id. Waits briefly because
    the SNS record can arrive a moment after the customer taps "I've uploaded ..."."""
    deadline = time.time() + wait_seconds
    while True:
        rows = []
        for cid in dict.fromkeys(c for c in contact_ids if c):
            rows += db_query(f"ATTACH#{cid}", newest_first=True, limit=5)
        rows = [r for r in rows if r.get("attachment_id") != exclude_id and r.get("status", "").upper() != "REJECTED"]
        if rows:
            return max(rows, key=lambda r: r["sk"])
        if time.time() >= deadline:
            return None
        time.sleep(0.8)


def _day_prefixes(absolute_time):
    days = []
    try:
        days.append(datetime.fromisoformat(absolute_time.replace("Z", "+00:00")).astimezone(timezone.utc))
    except (ValueError, AttributeError):
        pass
    now = datetime.now(timezone.utc)
    days += [now, now - timedelta(days=1)]
    base = f"{ATTACHMENTS_PREFIX}/chat" if ATTACHMENTS_PREFIX else "chat"
    return list(dict.fromkeys(d.strftime(f"{base}/%Y/%m/%d/") for d in days))


def _find_key(attachment_id, absolute_time):
    s3 = client("s3")
    for day in _day_prefixes(absolute_time):
        r = s3.list_objects_v2(Bucket=ATTACHMENTS_BUCKET, Prefix=day + attachment_id, MaxKeys=5)
        keys = [o["Key"] for o in r.get("Contents", [])]
        if keys:
            return keys[0]
    # Fallback if the object name does not start with the attachment id: scan the day folder for it.
    for day in _day_prefixes(absolute_time)[:1]:
        token, pages = None, 0
        while pages < 10:
            kw = {"Bucket": ATTACHMENTS_BUCKET, "Prefix": day, "MaxKeys": 1000}
            if token:
                kw["ContinuationToken"] = token
            r = s3.list_objects_v2(**kw)
            for o in r.get("Contents", []):
                if attachment_id in o["Key"]:
                    return o["Key"]
            token, pages = r.get("NextContinuationToken"), pages + 1
            if not token:
                break
    return None


def load_attachment(row, max_bytes, wait_seconds=4.0):
    """-> (bytes, size) or (None, size). Size is known even when the file is too large to load."""
    aid = row["attachment_id"]
    if LOCAL_MODE:
        data = LOCAL_FILES.get(aid, (None, ""))[0]
        return (data, len(data)) if data else (None, 0)
    if not ATTACHMENTS_BUCKET:
        raise RuntimeError("ATTACHMENTS_BUCKET is not configured")
    deadline, key = time.time() + wait_seconds, None
    while key is None:
        key = _find_key(aid, row.get("absolute_time", ""))
        if key or time.time() >= deadline:
            break
        time.sleep(1.0)
    if not key:
        log("attachment_not_in_s3", attachment_id=aid)
        return None, 0
    s3 = client("s3")
    size = s3.head_object(Bucket=ATTACHMENTS_BUCKET, Key=key)["ContentLength"]
    if size > max_bytes:
        return None, size
    return s3.get_object(Bucket=ATTACHMENTS_BUCKET, Key=key)["Body"].read(), size
