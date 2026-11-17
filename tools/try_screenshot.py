"""Try a screenshot against the DEPLOYED bot without a real chat (same steps as the Connect flow).

  python3 tools/try_screenshot.py samples/unrelated_sales_report_screenshot.png [more images ...]

Uses .deploy_settings (instance + prefix) and your AWS credentials. Each image is "uploaded" the way the chat
does it (object under the instance's ATTACHMENTS prefix + the attachment record that stream.py writes), then:
  bot "I can't sign in to the intranet" -> upload -> bot "done" -> analyze Lambda (async step of the flow)
  -> bot "__ANALYSIS_READY__"
Several images are uploaded one after another in the same conversation, so the retry path is visible too.
Everything the test writes (S3 objects, DynamoDB items) is deleted at the end.
"""
import datetime
import json
import os
import sys
import time
import uuid

import boto3

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def setting(key):
    for line in open(os.path.join(HERE, ".deploy_settings")):
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return ""


arn, prefix = setting("CONNECT_INSTANCE_ARN"), setting("NAME_PREFIX") or "ith"
region, instance_id = arn.split(":")[3], arn.rsplit("/", 1)[1]
lam = boto3.client("lambda", region_name=region)
s3 = boto3.client("s3", region_name=region)
ddb = boto3.client("dynamodb", region_name=region)
connect = boto3.client("connect", region_name=region)
cfg = connect.list_instance_storage_configs(InstanceId=instance_id, ResourceType="ATTACHMENTS")["StorageConfigs"][0]["S3Config"]
bucket, att_prefix = cfg["BucketName"], cfg.get("BucketPrefix", "").strip("/")
table, bot_fn, analyze_fn = f"{prefix}-chat-ai", f"{prefix}-chat-ai-bot", f"{prefix}-chat-ai-analyze"
cid = "SMOKE-" + uuid.uuid4().hex[:12]
written_keys = []


def invoke(fn, payload):
    r = json.loads(lam.invoke(FunctionName=fn, Payload=json.dumps(payload).encode())["Payload"].read())
    if "errorMessage" in r:
        sys.exit(f"Lambda error: {r['errorMessage']}")
    return r


def say(text, attrs):
    r = invoke(bot_fn, {"sessionId": cid, "inputTranscript": text, "inputMode": "Text", "invocationSource": "FulfillmentCodeHook",
                        "sessionState": {"sessionAttributes": attrs, "intent": {"name": "HelpdeskIntent", "state": "ReadyForFulfillment"}}})
    print(f"\nUSER: {text}")
    for m in r.get("messages", []):
        if m["contentType"] == "CustomPayload":
            c = json.loads(m["content"])["data"]["content"]
            print(f"  BOT [{json.loads(m['content'])['templateType']}] {c['title']} -> {[e['title'] for e in c['elements']]}")
        else:
            print(f"  BOT: {m['content']}")
    a = r["sessionState"]["sessionAttributes"]
    print(f"  ({r['sessionState']['dialogAction']['type']}, stage={a.get('stage')}, next_step={a.get('next_step')}, "
          f"target_queue={a.get('target_queue')}, shot_category={a.get('shot_category')}, upload_misses={a.get('upload_misses')})")
    return a


def upload(path):
    aid = "SMOKE" + uuid.uuid4().hex[:10]
    now = datetime.datetime.now(datetime.timezone.utc)
    key = f"{att_prefix + '/' if att_prefix else ''}chat/{now:%Y/%m/%d}/{cid}_{aid}_{now:%Y%m%dT%H:%M}_UTC.png"
    s3.put_object(Bucket=bucket, Key=key, Body=open(path, "rb").read(), ContentType="image/png")
    written_keys.append(key)
    ddb.put_item(TableName=table, Item={
        "pk": {"S": f"ATTACH#{cid}"}, "sk": {"S": f"{now.isoformat()}#{aid}"}, "attachment_id": {"S": aid},
        "file_name": {"S": os.path.basename(path)}, "content_type": {"S": "image/png"}, "status": {"S": "APPROVED"},
        "absolute_time": {"S": now.isoformat()}, "ttl": {"N": str(int(now.timestamp()) + 3600)}})
    print(f"\n[customer uploads {os.path.basename(path)}]")


def cleanup():
    for k in written_keys:
        s3.delete_object(Bucket=bucket, Key=k)
    for pk in (f"ATTACH#{cid}", f"SESSION#{cid}", f"ANALYSIS#{cid}"):
        for it in ddb.query(TableName=table, KeyConditionExpression="pk = :p",
                            ExpressionAttributeValues={":p": {"S": pk}})["Items"]:
            ddb.delete_item(TableName=table, Key={"pk": it["pk"], "sk": it["sk"]})
    print(f"\n[test data removed: {len(written_keys)} S3 object(s) and the DynamoDB items of {cid}]")


images = sys.argv[1:] or [os.path.join(HERE, "samples", "unrelated_sales_report_screenshot.png")]
try:
    attrs = say("Hello", {"contact_id": cid, "initial_contact_id": cid})
    attrs = say("I can't sign in to the intranet", attrs)
    for img in images:
        upload(img)
        attrs = say("done", attrs)
        if attrs.get("next_step") != "ANALYZE":
            break
        t = time.time()
        res = invoke(analyze_fn, {"Name": "ContactFlowEvent", "Details": {"ContactData": {"ContactId": cid, "Channel": "CHAT"},
                                                                       "Parameters": {"contact_id": cid}}})
        print(f"  [flow: async analysis -> {res} in {time.time() - t:.1f}s, re-enter bot]")
        attrs = say("__ANALYSIS_READY__", {"contact_id": cid, "initial_contact_id": cid})
        if attrs.get("next_step") in ("TRANSFER", "END") or attrs.get("stage") != "AWAIT_SCREENSHOT":
            break
finally:
    cleanup()
