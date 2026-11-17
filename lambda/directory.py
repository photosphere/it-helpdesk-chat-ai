"""Mock employee directory and password-reset service (DynamoDB).

Replace ``reset_password`` / ``find_user`` with calls to your identity provider (for example Microsoft Entra ID
via Microsoft Graph, or on-premises AD through a private API) for production use. The chat never shows or asks
for a password: a self-service reset link is sent to the employee's registered personal email.
"""
import hashlib
import hmac
import re
import secrets

from common import (MAX_VERIFY_FAILS_PER_HOUR, RESET_LINK_MINUTES, db_get, db_put, db_query, epoch, iso_now, log,
                    mask_email)

EMPLOYEE_ID_RE = re.compile(r"\b([Ee]\d{5})\b")


def parse_employee_id(text):
    m = EMPLOYEE_ID_RE.search(text or "")
    return m.group(1).upper() if m else ""


def parse_last4(text):
    digits = re.sub(r"\D", "", text or "")
    return digits if len(digits) == 4 else ""


def find_user(employee_id):
    return db_get(f"USER#{employee_id}", "PROFILE") if employee_id else None


def recent_failures(employee_id):
    since = epoch() - 3600
    return sum(1 for r in db_query(f"VERIFYFAIL#{employee_id}", limit=50) if int(r.get("at", 0)) >= since)


def self_service_blocked(employee_id):
    return recent_failures(employee_id) >= MAX_VERIFY_FAILS_PER_HOUR


def record_failure(employee_id, contact_id):
    db_put({"pk": f"VERIFYFAIL#{employee_id}", "sk": f"{iso_now()}#{secrets.token_hex(3)}", "at": epoch(),
            "contact_id": contact_id, "ttl": epoch() + 2 * 3600})


def verify_phone(user, last4):
    return bool(last4) and hmac.compare_digest(str(user.get("phone_last4", "")), last4)


def reset_password(user, contact_id):
    """Unlock the account, require a new password at next sign-in, and issue a one-time reset link (mock delivery)."""
    token = secrets.token_urlsafe(24)
    db_put({"pk": f"RESET#{user['employee_id']}", "sk": iso_now(),
            "token_sha256": hashlib.sha256(token.encode()).hexdigest(), "contact_id": contact_id,
            "expires_at": epoch() + RESET_LINK_MINUTES * 60, "delivered_to": mask_email(user.get("personal_email")),
            "ttl": epoch() + 7 * 24 * 3600})
    updated = dict(user, locked=False, must_change_password=True, last_reset_at=iso_now(), last_reset_contact=contact_id)
    db_put(updated)
    log("password_reset", employee_id=user["employee_id"], contact_id=contact_id)  # never log the token
    return {"sent_to": mask_email(user.get("personal_email")), "expires_minutes": RESET_LINK_MINUTES}
