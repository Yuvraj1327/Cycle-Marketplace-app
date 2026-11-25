"""Push notification provider abstraction.

Firebase Cloud Messaging is the client's required push channel, but its credentials are not available yet. Everything that sends a push goes through this
interface, so nothing else in the backend knows about FCM, and until a provider is configured the platform reports 'not configured' instead of pretending
a message was delivered. Adapters must never log tokens or credentials."""
from dataclasses import dataclass, field
from typing import Protocol


@dataclass(frozen=True)
class PushMessage:
    """What the device receives. `data` values are strings (an FCM requirement) and carry ids only, never personal details."""

    title: str
    body: str
    data: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class PushResult:
    """status: sent | invalid_token (never use this token again) | retry (temporary, try later) | failed (will not be retried)."""

    status: str
    detail: str = ""


class PushProvider(Protocol):
    name: str

    def is_configured(self) -> bool: ...
    def send(self, token: str, message: PushMessage) -> PushResult: ...


class UnconfiguredPush:
    """Used while no push provider is configured: sending is refused loudly instead of being simulated."""

    name = ""

    def is_configured(self) -> bool:
        return False

    def send(self, token: str, message: PushMessage) -> PushResult:  # pragma: no cover - the dispatcher never calls an unconfigured provider
        return PushResult("failed", "push provider not configured")
