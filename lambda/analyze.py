"""Asynchronous image analysis, invoked by the chat flow ("Invoke AWS Lambda function", Execution mode Asynchronous).

The bot hands off with Lex session attribute next_step=ANALYZE after saving its state (SESSION#<contactId>).
The flow sends nothing itself: the bot's closing message already told the customer the analysis is running.
Flow: Invoke this Lambda asynchronously -> Wait (timer) -> Load Lambda result -> InProgress? back to Wait.
When the result is loaded, the flow re-enters the Lex bot with initial message __ANALYSIS_READY__ and the bot
reads the result saved here (ANALYSIS#<contactId>), so the customer gets the answer without typing anything.

Returns a flat JSON object {"status": ...}. Errors are caught and returned as status FAILED, because Connect
retries a Lambda that raises.
"""
import attachments
import vision
from common import db_put, epoch, iso_now, load_session, log

MODES = ("LOGIN", "HARDWARE")


def analyze(contact_id):
    state = load_session(contact_id) or {}
    mode = state.get("analysis_mode", "LOGIN")
    if mode not in MODES:
        mode = "LOGIN"
    result = {"status": "FAILED", "mode": mode, "attachment_id": "", "size": 0}
    row = attachments.newest_attachment([contact_id, state.get("initial_contact_id")],
                                        exclude_id=state.get("last_attachment_id", ""), wait_seconds=8.0)
    if not row:
        result["status"] = "NO_IMAGE"
        return result
    result["attachment_id"] = row["attachment_id"]
    fmt = vision.image_format(row.get("content_type"), row.get("file_name"))
    if not fmt:
        result["status"] = "UNSUPPORTED"
        return result
    data, size = attachments.load_attachment(row, vision.MAX_IMAGE_BYTES, wait_seconds=8.0)
    result["size"] = size
    if not data:
        result["status"] = "TOO_LARGE" if size else "UNREADABLE_FILE"
        return result
    result["analysis"] = vision.analyze_image(data, fmt, mode)
    result["status"] = "OK"
    return result


def lambda_handler(event, context):
    cd = (event.get("Details") or {}).get("ContactData") or {}
    params = (event.get("Details") or {}).get("Parameters") or {}
    contact_id = params.get("contact_id") or cd.get("ContactId", "")
    try:
        result = analyze(contact_id)
    except Exception as e:  # report, do not raise (Connect would retry and analyze again)
        log("analysis_failed", contact_id=contact_id, error=repr(e))
        result = {"status": "FAILED", "mode": "", "attachment_id": "", "size": 0, "error": str(e)[:300]}
    db_put({"pk": f"ANALYSIS#{contact_id}", "sk": "LATEST", "result": result, "at": iso_now(), "ttl": epoch() + 86400})
    log("analysis_done", contact_id=contact_id, status=result["status"], mode=result.get("mode"),
        category=(result.get("analysis") or {}).get("error_category"))
    return {"status": result["status"], "mode": result.get("mode", "")}
