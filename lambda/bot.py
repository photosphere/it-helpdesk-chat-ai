"""Lex V2 fulfillment code hook: the IT Helpdesk chat conversation (English only).

Every customer turn reaches this function (HelpdeskIntent and FallbackIntent both have the fulfillment code
hook enabled). The conversation state lives in Lex session attributes (``stage`` etc.). Each reply is either

* ElicitIntent - keep the customer in the bot and wait for the next message, or
* Close        - leave the bot; the Connect flow reads session attribute ``next_step``
                 (TRANSFER -> queue named by ``target_queue`` IT|SECURITY, END -> disconnect).

Choices are shown as Connect interactive messages: ListPicker (main menu, "did that fix it?") and
Panel (sub-menus). A tapped choice comes back as its title text.

Scenario: employee cannot sign in to the intranet -> uploads the error screenshot -> Bedrock multimodal
analysis -> identity verification -> password reset (mock directory) -> confirmation, or hand-off to an agent
with an AI summary in the contact attributes.
"""
import re

import attachments
import directory
import templates as T
import vision
from common import (COMPANY_NAME, INSTANCE_ID, LOCAL_MODE, MAX_VERIFY_FAILS, client, load_analysis, load_session,
                    log, norm, save_session)

# ---------------------------------------------------------------- choices (titles are matched on the way back)
OPT_ACCOUNT = "Account & sign-in issues"
OPT_HARDWARE = "Hardware & peripherals"
OPT_AGENT = "Talk to an agent"
OPT_END = "End chat"
OPT_CANT_SIGN_IN = "I can't sign in to the intranet"
OPT_LOCKED = "My account is locked"
OPT_MFA = "MFA or verification code issue"
OPT_MENU = "Main menu"
OPT_UPLOADED = "I've uploaded the screenshot"
OPT_NO_SCREENSHOT = "I don't have a screenshot"
OPT_RESET = "Reset my password"
OPT_FIXED = "Yes, I can sign in now"
OPT_NOT_FIXED = "No, I still can't sign in"
OPT_PHOTO_UPLOADED = "I've uploaded a photo"

AGENT_WORDS = ("agent", "human", "representative", "real person", "someone", "operator", "live support")
MENU_WORDS = ("main menu", "menu", "start over", "restart", "back")
END_WORDS = ("end chat", "bye", "goodbye", "that's all", "thats all", "no thanks", "nothing else", "quit", "exit")
UPLOAD_WORDS = ("uploaded", "attached", "sent it", "done", "there you go", "here it is")
MAX_UPLOAD_MISSES = 3
# Initial messages the chat flow sends to the bot after the asynchronous analysis Lambda.
ANALYSIS_READY = "__ANALYSIS_READY__"
ANALYSIS_FAILED = "__ANALYSIS_FAILED__"
MAX_UNCLEAR = 2


# ---------------------------------------------------------------- Lex response helpers
def _session(event):
    return dict((event.get("sessionState") or {}).get("sessionAttributes") or {})


def elicit(attrs, *messages):
    return {"sessionState": {"dialogAction": {"type": "ElicitIntent"}, "sessionAttributes": _str(attrs)},
            "messages": list(messages)}


def close(event, attrs, *messages):
    intent = dict((event.get("sessionState") or {}).get("intent") or {"name": "HelpdeskIntent"})
    intent["state"] = "Fulfilled"
    intent.pop("slots", None)
    return {"sessionState": {"dialogAction": {"type": "Close"}, "intent": intent, "sessionAttributes": _str(attrs)},
            "messages": list(messages)}


def _str(attrs):
    return {k: str(v) for k, v in attrs.items() if v is not None}


def _has(t, words):
    return any(re.search(rf"(^|\s){re.escape(w)}($|\s)", t) for w in words)


def _is(t, option):
    return t == norm(option)


# ---------------------------------------------------------------- menus
def main_menu(attrs, intro=None):
    attrs.update(stage="MENU", unclear="0")
    msgs = [T.text(intro)] if intro else []
    msgs.append(T.list_picker("How can I help you today?", [OPT_ACCOUNT, OPT_HARDWARE, OPT_AGENT, OPT_END]))
    return elicit(attrs, *msgs)


def account_menu(attrs):
    attrs.update(stage="ACCOUNT", unclear="0")
    return elicit(attrs, T.panel("What kind of account problem do you have?",
                                 [OPT_CANT_SIGN_IN, OPT_LOCKED, OPT_MFA, OPT_AGENT, OPT_MENU]))


# The chat widget shows the buttons of an interactive message only while it is the latest message, so the buttons
# disappear as soon as the customer uploads a file. Every prompt therefore also tells the customer to type "done",
# and in the upload stages any typed text is treated as "uploaded" when an upload is found.
UPLOAD_HINT = "When the file shows in the chat, type \"done\"."


def ask_screenshot(attrs, intro=None):
    attrs.update(stage="AWAIT_SCREENSHOT", topic=attrs.get("topic") or "Cannot sign in to the intranet")
    msgs = [T.text((intro or "Sorry you're having trouble signing in. Please take a screenshot of the error on your "
                             "sign-in page and upload it here with the attachment (paperclip) icon. Please don't type "
                             "your password in this chat.") + " " + UPLOAD_HINT)]
    msgs.append(T.panel("No screenshot? Choose an option.", [OPT_NO_SCREENSHOT, OPT_AGENT], subtitle=""))
    return elicit(attrs, *msgs)


def ask_employee_id(attrs, intro=None):
    attrs.update(stage="AWAIT_EMPLOYEE_ID")
    return elicit(attrs, T.text((intro + " " if intro else "") +
                                "First I need to verify your identity. Please type your employee ID "
                                "(for example E12345). You can find it on your badge."))


def hardware_menu(attrs):
    attrs.update(stage="HARDWARE", topic="Hardware or peripheral problem")
    return elicit(attrs,
                  T.text("I can take a first look. Please upload a clear photo of the device, including any error "
                         "message, indicator lights and the asset tag if you can, using the attachment (paperclip) "
                         "icon. " + UPLOAD_HINT),
                  T.panel("No photo? Choose an option.", [OPT_AGENT, OPT_MENU], subtitle=""))


# ---------------------------------------------------------------- hand-off / end
def transfer(event, attrs, reason, queue="IT", message=None):
    attrs.update(next_step="TRANSFER", target_queue=queue, handoff_reason=reason, stage="DONE")
    summary = _summary(attrs, reason)
    _update_contact_attributes(attrs, {
        "ai_summary": summary, "ai_topic": attrs.get("topic", ""), "ai_handoff_reason": reason,
        "ai_screenshot_category": attrs.get("shot_category", ""), "ai_screenshot_error": attrs.get("shot_error", ""),
        "ai_employee_id": attrs.get("employee_id", ""), "ai_identity_verified": attrs.get("verified", "false"),
        "ai_reset_status": attrs.get("reset_status", "NOT_STARTED"), "ai_target_queue": queue})
    msg = message or ("I'm connecting you to an IT Helpdesk agent now. I've shared a summary of our chat, "
                      "so you won't need to repeat yourself.")
    log("transfer", contact_id=attrs.get("contact_id"), queue=queue, reason=reason)
    return close(event, attrs, T.text(msg))


def end(event, attrs, message="Thanks for contacting the IT Helpdesk. Have a great day!"):
    attrs.update(next_step="END", stage="DONE")
    _update_contact_attributes(attrs, {"ai_summary": _summary(attrs, "Resolved by the virtual assistant"),
                                       "ai_reset_status": attrs.get("reset_status", "NOT_STARTED"),
                                       "ai_resolved": "true" if attrs.get("reset_status") == "LINK_SENT" else "false"})
    return close(event, attrs, T.text(message))


def _summary(attrs, reason):
    parts = [f"Topic: {attrs.get('topic') or 'not chosen'}.", f"Hand-off reason: {reason}."]
    if attrs.get("shot_category"):
        parts.append(f"Screenshot: {attrs['shot_category']} on {attrs.get('shot_app') or 'unknown system'}"
                     f"{' (' + attrs['shot_domain'] + ')' if attrs.get('shot_domain') else ''}; "
                     f"error text: \"{attrs.get('shot_error') or 'n/a'}\".")
    if attrs.get("shot_user"):
        parts.append(f"Username on screenshot: {attrs['shot_user']}.")
    if attrs.get("employee_id"):
        parts.append(f"Employee ID given: {attrs['employee_id']}, verified: {attrs.get('verified', 'false')}.")
    if attrs.get("reset_status"):
        parts.append(f"Password reset: {attrs['reset_status']}.")
    if attrs.get("username_mismatch") == "true":
        parts.append("Note: the username on the screenshot does not match the directory account.")
    return " ".join(parts)[:1000]


def _update_contact_attributes(attrs, values):
    cid = attrs.get("contact_id", "")
    if LOCAL_MODE or not INSTANCE_ID or not cid or cid.startswith("SMOKE-"):
        return
    try:
        client("connect").update_contact_attributes(InstanceId=INSTANCE_ID, InitialContactId=cid,
                                                    Attributes={k: str(v)[:32000] for k, v in values.items()})
    except Exception as e:  # the hand-off itself must not fail because of the summary
        log("update_contact_attributes_failed", error=str(e), contact_id=cid)


# ---------------------------------------------------------------- stages
def stage_start(event, t, raw, attrs):
    if attrs.get("greeted") != "true":
        attrs["greeted"] = "true"
        intro = f"Hi, I'm the {COMPANY_NAME} IT Helpdesk virtual assistant."
        # The chat may start with a real question (initial message) instead of the flow's greeting.
        if t and t not in ("hello", "hi", "hey", "start", "start helpdesk"):
            routed = _route_free_text(event, t, raw, attrs, intro=intro)
            if routed:
                return routed
        return main_menu(attrs, intro)
    return stage_menu(event, t, raw, attrs)


def stage_menu(event, t, raw, attrs):
    if _is(t, OPT_ACCOUNT):
        attrs["topic"] = "Account / sign-in"
        return account_menu(attrs)
    if _is(t, OPT_HARDWARE):
        return hardware_menu(attrs)
    return _route_free_text(event, t, raw, attrs) or _unclear(event, attrs, main_menu)


def stage_account(event, t, raw, attrs):
    if _is(t, OPT_CANT_SIGN_IN):
        attrs["topic"] = "Cannot sign in to the intranet"
        return ask_screenshot(attrs)
    if _is(t, OPT_LOCKED):
        attrs["topic"] = "Account locked"
        return ask_screenshot(attrs, "I can help you unlock your account. If you see an error on the sign-in page, "
                                     "please upload a screenshot of it with the attachment (paperclip) icon. "
                                     "Please don't type your password in this chat.")
    if _is(t, OPT_MFA):
        attrs["topic"] = "MFA / verification code problem"
        return transfer(event, attrs, "MFA re-registration needs an agent")
    return _route_free_text(event, t, raw, attrs) or _unclear(event, attrs, account_menu)


def stage_await_screenshot(event, t, raw, attrs):
    if _is(t, OPT_NO_SCREENSHOT):
        attrs["stage"] = "OFFER_RESET"
        return elicit(attrs, T.text("No problem. If the problem is a forgotten or expired password, or a locked "
                                    "account, I can reset it for you after a quick identity check."),
                      T.panel("What would you like to do?", [OPT_RESET, OPT_AGENT, OPT_MENU]))
    # "done", "uploaded", the old button text or anything else typed after the upload: look for the upload.
    # start_analysis asks again (and counts a miss) when no new upload is found.
    return start_analysis(event, attrs, "LOGIN")


def _upload_problem(event, attrs, mode, problem):
    """Explain why the image can't be used and ask again (or hand off after MAX_UPLOAD_MISSES)."""
    misses = int(attrs.get("upload_misses", "0")) + 1
    attrs["upload_misses"] = str(misses)
    if misses >= MAX_UPLOAD_MISSES:
        return transfer(event, attrs, "Customer could not share a usable image")
    what = "screenshot" if mode == "LOGIN" else "photo"
    msg = problem.format(what=what)
    if mode == "LOGIN":
        return ask_screenshot(attrs, msg)
    attrs["stage"] = "HARDWARE"
    return elicit(attrs, T.text(msg + " " + UPLOAD_HINT),
                  T.panel("No photo? Choose an option.", [OPT_AGENT, OPT_MENU], subtitle=""))


NO_UPLOAD = "I can't see a new {what} in our chat yet. Please upload it with the attachment (paperclip) icon."


def start_analysis(event, attrs, mode):
    """Hand the image analysis to the flow's asynchronous Lambda (Connect waits up to 60 s, Lex code hooks can't).

    Only a quick check here that an upload exists; the S3 read and the Bedrock call run in analyze.py.
    The bot state is saved so that the bot can continue when the flow re-enters it with ANALYSIS_READY."""
    row = attachments.newest_attachment([attrs.get("contact_id"), attrs.get("initial_contact_id")],
                                        exclude_id=attrs.get("last_attachment_id", ""), wait_seconds=3.0)
    if not row:
        return _upload_problem(event, attrs, mode, NO_UPLOAD)
    if not vision.image_format(row.get("content_type"), row.get("file_name")):
        attrs["last_attachment_id"] = row["attachment_id"]
        return _upload_problem(event, attrs, mode, "That file type isn't supported. Please upload the {what} as a "
                                                   "PNG or JPG image.")
    attrs.update(analysis_mode=mode, stage="ANALYZING", next_step="ANALYZE")
    save_session(attrs.get("contact_id", ""), attrs)
    what = "screenshot" if mode == "LOGIN" else "photo"
    log("analysis_handoff", contact_id=attrs.get("contact_id"), mode=mode, attachment_id=row["attachment_id"])
    return close(event, attrs, T.text(f"Thanks! I'm analyzing your {what} now. This usually takes a few seconds."))


def resume_after_analysis(event, attrs, ok):
    """Flow re-entered the bot with ANALYSIS_READY / ANALYSIS_FAILED: restore the state, apply the result."""
    cid = attrs.get("contact_id", "")
    saved = load_session(cid) or {}
    attrs = dict(saved, **{k: v for k, v in attrs.items() if k in ("contact_id", "initial_contact_id")})
    attrs.pop("next_step", None)
    attrs.pop("target_queue", None)
    mode = attrs.get("analysis_mode", "LOGIN")
    result = load_analysis(cid) if ok else None
    status = (result or {}).get("status", "FAILED")
    if result and result.get("attachment_id"):
        attrs["last_attachment_id"] = result["attachment_id"]
    log("analysis_resume", contact_id=cid, status=status, mode=mode)
    if status == "OK":
        return apply_login_result(event, attrs, result["analysis"]) if mode == "LOGIN" \
            else apply_hardware_result(event, attrs, result["analysis"])
    if status == "NO_IMAGE":
        return _upload_problem(event, attrs, mode, NO_UPLOAD)
    if status == "UNSUPPORTED":
        return _upload_problem(event, attrs, mode, "That file type isn't supported. Please upload the {what} as a "
                                                   "PNG or JPG image.")
    if status == "TOO_LARGE":
        return _upload_problem(event, attrs, mode, "That image is too large for me to read. Please crop it or upload "
                                                   "a smaller PNG or JPG (under 3.5 MB).")
    if status == "UNREADABLE_FILE":
        return _upload_problem(event, attrs, mode, "I couldn't open that file. Please try uploading the {what} again.")
    what = "screenshot" if mode == "LOGIN" else "photo"
    return transfer(event, attrs, f"{what.capitalize()} analysis failed or timed out",
                    message=f"Sorry, I couldn't analyze your {what} right now. I'm connecting you to an IT Helpdesk "
                            f"agent, who can see the {what} you uploaded.")


def apply_login_result(event, attrs, a):
    cat = a.get("error_category", "OTHER_LOGIN_ERROR")
    attrs.update(shot_category=cat, shot_app=(a.get("application") or "")[:80], shot_domain=(a.get("domain") or "")[:100],
                 shot_error=(a.get("error_text") or "")[:200], shot_user=(a.get("username_shown") or "")[:80])
    log("screenshot_analyzed", contact_id=attrs.get("contact_id"), category=cat, domain=a.get("domain"),
        app=a.get("application"))
    reply = a.get("user_reply") or "Thanks, I've looked at your screenshot."
    caution = (" I can see a password or code in clear text in your screenshot. Please don't share these with anyone; "
               "a reset will make the old password useless.") if a.get("secret_visible") else ""

    # Wrong or unreadable image: ask for a new upload (counts as a miss; MAX_UPLOAD_MISSES -> agent).
    # Checked before the domain: the phishing check only applies to sign-in pages.
    if cat == "NOT_A_LOGIN_SCREEN":
        shown = (a.get("application") or "").strip()
        what = f"shows {shown}" if shown else "doesn't show a sign-in page"
        return _upload_problem(event, attrs, "LOGIN",
                               f"That screenshot {what}, not a sign-in error. Please upload a screenshot of the "
                               "intranet sign-in page that shows the error message.".replace("{", "(").replace("}", ")"))
    if cat == "UNREADABLE":
        return _upload_problem(event, attrs, "LOGIN", "I couldn't read that screenshot clearly. Please upload a sharper, "
                                                      "full-size screenshot of the sign-in page that shows the error message.")
    attrs["upload_misses"] = "0"

    if not vision.domain_is_trusted(a.get("domain")):
        attrs["topic"] = "Possible phishing sign-in page"
        return transfer(event, attrs, f"Sign-in page on untrusted domain {a.get('domain')}", queue="SECURITY",
                        message=f"Important: the page in your screenshot is on {a.get('domain')}, which is not an "
                                f"official {COMPANY_NAME} sign-in page. Please don't enter your password there. "
                                "I'm connecting you to our IT Security team now to secure your account.")
    if cat in ("WRONG_PASSWORD", "ACCOUNT_LOCKED", "PASSWORD_EXPIRED"):
        attrs["stage"] = "OFFER_RESET"
        return elicit(attrs, T.text(reply + caution),
                      T.panel("I can reset your password and unlock your account now.", [OPT_RESET, OPT_AGENT, OPT_MENU]))
    if cat == "ACCOUNT_DISABLED":
        return transfer(event, attrs, "Account appears disabled", message=reply + " A disabled account can only be "
                        "re-enabled by an agent, so I'm connecting you to the IT Helpdesk now.")
    if cat == "MFA_FAILURE":
        return transfer(event, attrs, "MFA failure shown on screenshot", message=reply + " MFA problems need an "
                        "agent to re-register your device, so I'm connecting you to the IT Helpdesk now.")
    # NETWORK_OR_VPN / OTHER_LOGIN_ERROR: give the explanation, then let the employee choose.
    attrs["stage"] = "OFFER_RESET"
    return elicit(attrs, T.text(reply + caution),
                  T.panel("What would you like to do next?", [OPT_RESET, OPT_AGENT, OPT_MENU]))


def apply_hardware_result(event, attrs, a):
    attrs.update(stage="HARDWARE", shot_category="HARDWARE", shot_app=(a.get("device") or "")[:80],
                 shot_error=(a.get("visible_issue") or "")[:200], upload_misses="0")
    return elicit(attrs, T.text(a.get("user_reply") or "Thanks for the photo."),
                  T.panel("If that didn't help, an agent can take over.", [OPT_AGENT, OPT_MENU, OPT_END]))


def stage_offer_reset(event, t, raw, attrs):
    if _is(t, OPT_RESET) or "reset" in t:
        return ask_employee_id(attrs)
    return _unclear(event, attrs, lambda a: elicit(a, T.panel("What would you like to do?", [OPT_RESET, OPT_AGENT, OPT_MENU])))


def _verify_failed(event, attrs, message):
    fails = int(attrs.get("verify_fails", "0")) + 1
    attrs["verify_fails"] = str(fails)
    if attrs.get("employee_id"):
        directory.record_failure(attrs["employee_id"], attrs.get("contact_id", ""))
    if fails >= MAX_VERIFY_FAILS:
        attrs["reset_status"] = "VERIFICATION_FAILED"
        return transfer(event, attrs, "Identity verification failed", queue="SECURITY",
                        message="For your protection I can't continue the self-service reset. I'm connecting you to "
                                "an IT Helpdesk agent who can verify your identity another way.")
    return elicit(attrs, T.text(message))


def stage_await_employee_id(event, t, raw, attrs):
    emp = directory.parse_employee_id(raw)
    if not emp:
        return _verify_failed(event, attrs, "That doesn't look like an employee ID. It starts with E followed by "
                                            "5 digits, for example E12345.")
    attrs["employee_id"] = emp
    if directory.self_service_blocked(emp):
        attrs["reset_status"] = "BLOCKED_TOO_MANY_ATTEMPTS"
        return transfer(event, attrs, "Too many failed verification attempts for this employee ID", queue="SECURITY",
                        message="There have been too many failed verification attempts for this account, so "
                                "self-service reset is paused. I'm connecting you to an agent.")
    user = directory.find_user(emp)
    if not user:
        attrs.pop("employee_id", None)
        return _verify_failed(event, attrs, "I couldn't find that employee ID. Please check it and type it again.")
    shot_user = norm(attrs.get("shot_user", ""))
    if shot_user and shot_user not in (norm(user.get("username")), norm(user.get("email"))):
        attrs["username_mismatch"] = "true"
    attrs["stage"] = "AWAIT_PHONE_LAST4"
    return elicit(attrs, T.text("Thanks. For security, please type the last 4 digits of the mobile number "
                                "registered in your HR profile."))


def stage_await_phone(event, t, raw, attrs):
    user = directory.find_user(attrs.get("employee_id", ""))
    last4 = directory.parse_last4(raw)
    if not user:
        return ask_employee_id(attrs, "Let's start the check again.")
    if not last4:
        return elicit(attrs, T.text("Please type just the last 4 digits of your registered mobile number."))
    if not directory.verify_phone(user, last4):
        return _verify_failed(event, attrs, "That doesn't match our records. Please try again.")
    attrs["verified"] = "true"
    if user.get("status") != "ACTIVE":
        attrs["reset_status"] = "ACCOUNT_DISABLED"
        return transfer(event, attrs, "Directory account is disabled",
                        message="Thanks, you're verified. Your account is disabled, which a self-service reset "
                                "can't fix. I'm connecting you to an IT Helpdesk agent.")
    if attrs.get("username_mismatch") == "true":
        attrs["reset_status"] = "USERNAME_MISMATCH"
        return transfer(event, attrs, "Screenshot username does not match the verified account",
                        message="Thanks, you're verified. The user name in your screenshot is different from your "
                                "account, so an agent will check this with you. Connecting you now.")
    r = directory.reset_password(user, attrs.get("contact_id", ""))
    attrs.update(reset_status="LINK_SENT", stage="RESOLVED_CHECK")
    unlocked = "I've unlocked your account and " if user.get("locked") else "I've "
    return elicit(attrs,
                  T.text(f"Thanks {user.get('name', '').split(' ')[0] or 'there'}, you're verified. {unlocked}sent a "
                         f"one-time password reset link to {r['sent_to']}. The link expires in {r['expires_minutes']} "
                         "minutes. Open it, choose a new password, then sign in to the intranet with the new password. "
                         "We will never ask for your password in chat."),
                  T.list_picker("Once you've set a new password, did that fix the problem?",
                                [OPT_FIXED, OPT_NOT_FIXED, OPT_MENU], subtitle="Tap to let me know"))


def stage_resolved_check(event, t, raw, attrs):
    if _is(t, OPT_FIXED) or t in ("yes", "yes it works", "it works", "fixed", "thanks", "thank you"):
        return end(event, attrs, "Great, I'm glad you're back in. Thanks for contacting the IT Helpdesk!")
    if _is(t, OPT_NOT_FIXED) or t.startswith("no"):
        return transfer(event, attrs, "Still cannot sign in after password reset")
    return _unclear(event, attrs, lambda a: elicit(a, T.list_picker("Did that fix the problem?",
                                                                    [OPT_FIXED, OPT_NOT_FIXED, OPT_MENU])))


def stage_hardware(event, t, raw, attrs):
    if _is(t, OPT_END):
        return end(event, attrs)
    analyzed = attrs.get("shot_category") == "HARDWARE"
    if analyzed and not (_is(t, OPT_PHOTO_UPLOADED) or _has(t, UPLOAD_WORDS)):
        return _unclear(event, attrs, lambda a: elicit(a, T.panel("If that didn't help, an agent can take over.",
                                                                  [OPT_AGENT, OPT_MENU, OPT_END])))
    # Waiting for a photo: "done" or anything else typed after the upload looks for the upload.
    return start_analysis(event, attrs, "HARDWARE")


def _route_free_text(event, t, raw, attrs, intro=None):
    """Typed text instead of a tapped choice: keywords first, then a Bedrock text classification."""
    label = None
    if re.search(r"\b(sign|log)\s?(in|on)\b|password|intranet|can't access|cannot access", t):
        label = "ACCOUNT_LOCKED" if "lock" in t else "SIGNIN_PROBLEM"
    elif "locked" in t:
        label = "ACCOUNT_LOCKED"
    elif re.search(r"\b(printer|monitor|screen|laptop|dock|keyboard|mouse|headset|webcam|cable|hardware)\b", t):
        label = "HARDWARE"
    elif len(t) > 3:
        label = vision.route_text(raw)
    prefix = (intro + " ") if intro else ""
    if label == "SIGNIN_PROBLEM":
        attrs["topic"] = "Cannot sign in to the intranet"
        return ask_screenshot(attrs, prefix + "Sorry you're having trouble signing in. Please take a screenshot of "
                                     "the error on your sign-in page and upload it here with the attachment (paperclip) "
                                     "icon. Please don't type your password in this chat.")
    if label == "ACCOUNT_LOCKED":
        attrs["topic"] = "Account locked"
        return ask_screenshot(attrs, prefix + "I can help you unlock your account. Please upload a screenshot of the "
                                     "error with the attachment (paperclip) icon. Please don't type your password here.")
    if label == "MFA_PROBLEM":
        attrs["topic"] = "MFA / verification code problem"
        return transfer(event, attrs, "MFA re-registration needs an agent")
    if label == "HARDWARE":
        return hardware_menu(attrs)
    if label == "AGENT":
        return transfer(event, attrs, "Customer asked for an agent")
    if label == "END":
        return end(event, attrs)
    return None


def _unclear(event, attrs, reprompt):
    n = int(attrs.get("unclear", "0")) + 1
    attrs["unclear"] = str(n)
    if n > MAX_UNCLEAR:
        return transfer(event, attrs, "Assistant could not understand the request")
    resp = reprompt(attrs)
    resp["messages"].insert(0, T.text("Sorry, I didn't catch that. Please tap one of the options below."))
    attrs["unclear"] = str(n)  # reprompt helpers may reset the counter
    resp["sessionState"]["sessionAttributes"] = _str(attrs)
    return resp


STAGES = {"": stage_start, "MENU": stage_menu, "ACCOUNT": stage_account, "AWAIT_SCREENSHOT": stage_await_screenshot,
          "OFFER_RESET": stage_offer_reset, "AWAIT_EMPLOYEE_ID": stage_await_employee_id,
          "AWAIT_PHONE_LAST4": stage_await_phone, "RESOLVED_CHECK": stage_resolved_check, "HARDWARE": stage_hardware}


def handle(event):
    attrs = _session(event)
    raw = (event.get("inputTranscript") or "").strip()
    t = norm(raw)
    stage = attrs.get("stage", "")
    secret_stage = stage in ("AWAIT_EMPLOYEE_ID", "AWAIT_PHONE_LAST4")
    log("turn", contact_id=attrs.get("contact_id"), stage=stage, text="<redacted>" if secret_stage else raw[:200])

    if raw in (ANALYSIS_READY, ANALYSIS_FAILED):  # initial message of the flow's re-entry after the async analysis
        return resume_after_analysis(event, attrs, ok=raw == ANALYSIS_READY)
    if stage == "ANALYZING":  # Lex re-entered without the marker (should not happen): show the result path anyway
        return resume_after_analysis(event, attrs, ok=True)

    if stage and not secret_stage:
        if _is(t, OPT_AGENT) or _has(t, AGENT_WORDS):
            return transfer(event, attrs, "Customer asked for an agent")
        if _is(t, OPT_END) or _has(t, END_WORDS):
            return end(event, attrs)
        if _is(t, OPT_MENU) or t in MENU_WORDS:
            return main_menu(attrs)
    elif secret_stage and (_is(t, OPT_AGENT) or t in ("agent", "human")):
        return transfer(event, attrs, "Customer asked for an agent during verification")
    return STAGES.get(stage, stage_start)(event, t, raw, attrs)


def lambda_handler(event, context):
    try:
        return handle(event)
    except Exception as e:  # never leave the customer without an answer
        log("bot_error", error=repr(e))
        attrs = _session(event)
        attrs.update(next_step="TRANSFER", target_queue="IT", handoff_reason="Virtual assistant error")
        return close(event, attrs, T.text("Sorry, something went wrong on my side. I'm connecting you to an IT "
                                          "Helpdesk agent."))
