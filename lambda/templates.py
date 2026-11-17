"""Amazon Connect interactive message builders (returned to Connect as Lex V2 CustomPayload messages).

Template formats: https://docs.aws.amazon.com/connect/latest/adminguide/interactive-messages.html
  * ListPicker - up to 6 choices
  * Panel      - up to 10 choices under one question
When the customer taps a choice, the chat sends the choice's ``title`` back as the customer's text,
so the bot matches on these titles.

A Lex V2 message ``content`` is limited to 1000 characters, so payloads are kept compact
(no images, short subtitles) and checked here.
"""
import json

LEX_MESSAGE_LIMIT = 1000


def text(message):
    message = (message or "").strip()
    if len(message) > LEX_MESSAGE_LIMIT:
        message = message[: LEX_MESSAGE_LIMIT - 3].rstrip() + "..."
    return {"contentType": "PlainText", "content": message}


def _interactive(template_type, max_items, title, options, subtitle):
    if not 1 <= len(options) <= max_items:
        raise ValueError(f"{template_type} needs 1..{max_items} options, got {len(options)}")
    content = {"title": title, "elements": [{"title": o} for o in options]}
    if subtitle:
        content["subtitle"] = subtitle
    payload = {"templateType": template_type, "version": "1.0", "data": {"content": content}}
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    if len(body) > LEX_MESSAGE_LIMIT and subtitle:
        content.pop("subtitle")
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    if len(body) > LEX_MESSAGE_LIMIT:
        raise ValueError(f"{template_type} payload is {len(body)} chars, Lex allows {LEX_MESSAGE_LIMIT}")
    return {"contentType": "CustomPayload", "content": body}


def list_picker(title, options, subtitle="Tap to select an option"):
    return _interactive("ListPicker", 6, title, options, subtitle)


def panel(title, options, subtitle="Tap to select an option"):
    return _interactive("Panel", 10, title, options, subtitle)
