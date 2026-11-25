"""Service-role access to device tokens and the push outbox (all through the SQL functions of migration 20)."""
from app.repositories.base import BaseRepository


class PushGateway(BaseRepository):
    table = "device_tokens"

    def __init__(self, admin_client):
        super().__init__(admin_client)

    def _call(self, fn: str, params: dict):
        return self._run(self.client.rpc(fn, params)).data

    def register(self, user_id: str, token: str, platform: str, app: str, label: str | None, version: str | None) -> str:
        return self._call("register_device_token", {"p_user": user_id, "p_token": token, "p_platform": platform, "p_app": app, "p_label": label, "p_version": version})

    def unregister(self, user_id: str, token: str) -> int:
        return int(self._call("deactivate_device_token", {"p_user": user_id, "p_token": token}) or 0)

    def claim(self, limit: int, max_attempts: int, max_age_hours: int) -> list[dict]:
        return self._call("claim_pending_pushes", {"p_limit": limit, "p_max_attempts": max_attempts, "p_max_age": f"{max_age_hours} hours"}) or []

    def finish(self, notification_id: str, status: str, error: str | None, retry_seconds: int | None, invalid_token_ids: list[str]) -> None:
        self._call("finish_push", {"p_id": notification_id, "p_status": status, "p_error": error, "p_retry_seconds": retry_seconds, "p_invalid_token_ids": invalid_token_ids or None})

    def status(self) -> dict:
        return self._call("admin_push_status", {}) or {}
