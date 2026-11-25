"""Chooses the push provider from configuration. Without Firebase credentials the platform runs with `UnconfiguredPush`: in-app notifications work, push is
reported as 'not configured' and nothing is simulated."""
from functools import lru_cache

from app.core.config import get_settings
from app.integrations.push.base import PushProvider, UnconfiguredPush
from app.integrations.push.fcm import build_fcm


@lru_cache
def _build(project: str, file: str, inline_hash: int) -> PushProvider:        # cached so the OAuth token is reused between sends
    return build_fcm(get_settings()) or UnconfiguredPush()


def get_push_provider() -> PushProvider:
    s = get_settings()
    return _build(s.fcm_project_id, s.fcm_service_account_file, hash(s.fcm_service_account_json))
