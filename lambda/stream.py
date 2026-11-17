"""Chat message streaming: start it from the flow, and record customer attachments from SNS.

Entry points (one function):
* Connect flow "Invoke AWS Lambda function" event (has ``Details.ContactData``) -> StartContactStreaming
  to the SNS topic. Returns a flat string map ({"streaming": "STARTED" | "FAILED"}).
* SNS event (``Records[].Sns``) -> for every CUSTOMER message that carries attachments, store
  ATTACH#<ContactId> (and ATTACH#<InitialContactId>) so bot.py can find the newest upload.
"""
import json

import attachments
from common import INSTANCE_ID, STREAM_TOPIC_ARN, client, log


def start_streaming(event):
    cd = event["Details"]["ContactData"]
    contact_id = cd["ContactId"]
    if cd.get("Channel") != "CHAT":
        return {"streaming": "SKIPPED"}
    try:
        client("connect").start_contact_streaming(
            InstanceId=INSTANCE_ID or cd["InstanceARN"].rsplit("/", 1)[-1], ContactId=contact_id,
            ChatStreamingConfiguration={"StreamingEndpointArn": STREAM_TOPIC_ARN}, ClientToken=contact_id)
        log("streaming_started", contact_id=contact_id)
        return {"streaming": "STARTED"}
    except Exception as e:  # the chat continues; the bot will say it cannot see the upload and offer an agent
        log("streaming_failed", contact_id=contact_id, error=str(e))
        return {"streaming": "FAILED"}


def on_sns(event):
    stored = 0
    for rec in event.get("Records", []):
        sns = rec.get("Sns") or {}
        try:
            msg = json.loads(sns.get("Message") or "{}")
        except json.JSONDecodeError:
            continue
        if msg.get("ParticipantRole") != "CUSTOMER":
            continue
        items = msg.get("Attachments") or []
        if not items:
            continue
        ids = [msg.get("ContactId"), msg.get("InitialContactId")]
        for a in items:
            if not a.get("AttachmentId"):
                continue
            for cid in dict.fromkeys(i for i in ids if i):
                attachments.record_attachment(cid, a, msg.get("AbsoluteTime", ""))
                stored += 1
            log("attachment_recorded", contact_id=msg.get("ContactId"), attachment_id=a.get("AttachmentId"),
                content_type=a.get("ContentType"), status=a.get("Status"))
    return {"stored": stored}


def lambda_handler(event, context):
    if "Records" in event:
        return on_sns(event)
    if "Details" in event:
        return start_streaming(event)
    log("unknown_event", keys=list(event.keys()))
    return {"streaming": "IGNORED"}
