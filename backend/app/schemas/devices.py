from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, StringConstraints

from app.schemas.common import StrictModel


class DeviceRegister(StrictModel):
    """`app` must match the account's role (customer app = customer account, vendor app = vendor account); the backend checks it."""

    token: Annotated[str, StringConstraints(min_length=20, max_length=4096)]
    platform: Literal["android", "ios", "web"]
    app: Literal["customer", "vendor"]
    device_label: Annotated[str, StringConstraints(max_length=100)] | None = None
    app_version: Annotated[str, StringConstraints(max_length=30)] | None = None


class DeviceUnregister(StrictModel):
    token: Annotated[str, StringConstraints(min_length=20, max_length=4096)]


class DeviceOut(BaseModel):
    registered: bool


class UnregisterOut(BaseModel):
    unregistered: bool


class PushStatus(BaseModel):
    """Admin view of push delivery. Never contains a token or a credential."""

    configured: bool
    provider: str | None
    dispatcher_enabled: bool
    by_status: dict[str, int]
    active_devices: dict[str, int]
    oldest_pending: datetime | None
    recent_failures: list[dict[str, Any]]


class DispatchResult(BaseModel):
    configured: bool
    claimed: int
    sent: int
    retry: int
    failed: int
    skipped: int
