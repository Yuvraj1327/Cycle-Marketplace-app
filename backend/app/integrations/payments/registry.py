"""Chooses the payment provider from configuration (PAYMENT_PROVIDER). Adapters register themselves with `register_adapter`.
No adapter is registered by default, so until the client picks a provider (and credentials exist) online payments report
'not configured'."""
from collections.abc import Callable

from app.core.config import Settings, get_settings
from app.integrations.payments.base import PaymentProvider, UnconfiguredProvider

_ADAPTERS: dict[str, Callable[[Settings], PaymentProvider]] = {}


def register_adapter(name: str, factory: Callable[[Settings], PaymentProvider]) -> None:
    _ADAPTERS[name.lower()] = factory


def get_payment_provider() -> PaymentProvider:
    settings = get_settings()
    factory = _ADAPTERS.get(settings.payment_provider.strip().lower())
    return factory(settings) if factory else UnconfiguredProvider()
