"""Delivers pending in-app notifications as push messages - AFTER the business transaction that created them has committed.

Why an outbox and not a call inside the request: a notification row is written by the same database transaction as the order / booking / payment it
describes, so it exists only if that transaction succeeded; this dispatcher then sends it later. If FCM is down, slow or not configured, the order or booking
is completely unaffected - the row simply stays 'pending' and is retried with back-off (or ends 'failed' / 'expired'), and the in-app notification is always there.
`claim_pending_pushes` leases rows with FOR UPDATE SKIP LOCKED, so several workers (or a worker and the admin 'dispatch now' button) never send the same notification twice."""
from __future__ import annotations

import logging

from app.core.config import Settings
from app.integrations.push.base import PushMessage, PushProvider
from app.repositories.push_repository import PushGateway

logger = logging.getLogger(__name__)

MAX_BODY = 180
MAX_TITLE = 100


def build_message(n: dict) -> PushMessage:
    """Only the user's own notification text plus ids. Order/booking details are fetched by the app after the user is signed in and the backend authorises the record."""
    data = {"notification_id": str(n["id"]), "type": str(n["type"])}
    if n.get("related_type") and n.get("related_id"):
        data.update(related_type=str(n["related_type"]), related_id=str(n["related_id"]))
    body = str(n["message"])
    return PushMessage(title=str(n["title"])[:MAX_TITLE], body=body if len(body) <= MAX_BODY else body[: MAX_BODY - 1] + "…", data=data)


def retry_delay(attempts: int) -> int:
    return min(30 * 2 ** max(attempts - 1, 0), 3600)


class PushDispatcher:
    def __init__(self, gateway: PushGateway, provider: PushProvider, settings: Settings):
        self.gateway, self.provider, self.settings = gateway, provider, settings

    def run_once(self, limit: int | None = None) -> dict:
        if not self.provider.is_configured():
            return {"configured": False, "claimed": 0, "sent": 0, "retry": 0, "failed": 0, "skipped": 0}
        rows = self.gateway.claim(limit or self.settings.push_batch_size, self.settings.push_max_attempts, self.settings.push_max_age_hours)
        out = {"configured": True, "claimed": len(rows), "sent": 0, "retry": 0, "failed": 0, "skipped": 0}
        for n in rows:
            outcome = self._deliver(n)
            out[outcome] += 1
        return out

    def _deliver(self, n: dict) -> str:
        tokens = n.get("tokens") or []
        if not tokens:
            self.gateway.finish(n["id"], "skipped", "the user has no registered device", None, [])
            return "skipped"
        message = build_message(n)
        sent, invalid, retry, failed, detail = 0, [], 0, 0, ""
        for t in tokens:
            try:
                res = self.provider.send(t["token"], message)
            except Exception:                                    # an adapter bug must not lose the other notifications in the batch
                logger.exception("push provider raised")
                res = None
            if res is None:
                retry, detail = retry + 1, "push provider error"
            elif res.status == "sent":
                sent += 1
            elif res.status == "invalid_token":
                invalid.append(t["id"])
            elif res.status == "retry":
                retry, detail = retry + 1, res.detail
            else:
                failed, detail = failed + 1, res.detail
        if sent:                                                  # at least one device got it: never resend (that would duplicate it on that device)
            self.gateway.finish(n["id"], "sent", None, None, invalid)
            return "sent"
        if retry and n.get("attempts", 1) < self.settings.push_max_attempts:
            self.gateway.finish(n["id"], "pending", detail, retry_delay(int(n.get("attempts", 1))), invalid)
            return "retry"
        if retry or failed:
            self.gateway.finish(n["id"], "failed", detail or "push could not be delivered", None, invalid)
            return "failed"
        self.gateway.finish(n["id"], "skipped", "all registered devices were no longer valid", None, invalid)
        return "skipped"
