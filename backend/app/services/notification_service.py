from __future__ import annotations

from uuid import UUID

from postgrest.types import CountMethod

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError
from app.repositories.base import BaseRepository
from app.services import _catalog

KEYS = ("id", "type", "title", "message", "related_type", "related_id", "is_read", "read_at", "created_at")


class NotificationService(BaseRepository):
    """The caller's own in-app notifications (user token => RLS; every query also filters by user_id). Recipients may only change the read state."""

    table = "notifications"

    def __init__(self, db):
        super().__init__(db)

    def list(self, user: CurrentUser, *, unread_only: bool, page: int, limit: int) -> dict:
        q = self.client.table(self.table).select("*", count=CountMethod.exact).eq("user_id", user.id)
        if unread_only:
            q = q.eq("is_read", False)
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        out = _catalog.page([{k: r.get(k) for k in KEYS} for r in res.data], res.count or 0, page, limit)
        return {**out, "unread_count": self.unread_count(user)}

    def unread_count(self, user: CurrentUser) -> int:
        return self._run(self.client.table(self.table).select("id", count=CountMethod.exact, head=True).eq("user_id", user.id).eq("is_read", False)).count or 0

    def mark_read(self, user: CurrentUser, notification_id: UUID) -> dict:
        res = self._run(self.client.table(self.table).update({"is_read": True}).eq("id", str(notification_id)).eq("user_id", user.id))
        if not res.data:
            raise NotFoundError("Notification not found.")
        return {k: res.data[0].get(k) for k in KEYS}

    def mark_all_read(self, user: CurrentUser) -> dict:
        res = self._run(self.client.table(self.table).update({"is_read": True}).eq("user_id", user.id).eq("is_read", False))
        return {"marked_read": len(res.data)}


