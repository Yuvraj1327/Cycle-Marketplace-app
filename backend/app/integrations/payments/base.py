"""Payment provider abstraction.

The client has NOT chosen a payment provider yet. This module defines the contract a provider adapter must satisfy; no concrete
provider ships with the code and nothing here pretends a payment succeeded. See docs/payments.md for what is needed to add one.

Adapters must:
  * never put secrets in `client_payload` (it is returned to the mobile app);
  * verify webhook authenticity themselves (`parse_webhook` raises InvalidWebhookSignature on any doubt);
  * translate provider-specific events into the canonical WebhookEvent types below.
"""
import hashlib
import hmac
from dataclasses import dataclass
from decimal import Decimal
from typing import Any, Mapping, Protocol

from app.core.exceptions import AppError

# canonical webhook event types understood by public.apply_payment_event
PAYMENT_EVENTS = {"payment.succeeded", "payment.failed", "payment.processing", "payment.cancelled", "refund.processed", "refund.failed"}


class PaymentProviderNotConfigured(AppError):
    status_code = 503
    code = "payment_provider_not_configured"
    message = "Online payments are not available yet: no payment provider is configured."


class PaymentProviderError(AppError):
    status_code = 502
    code = "payment_provider_error"
    message = "The payment provider could not process the request."


class InvalidWebhookSignature(AppError):
    status_code = 400
    code = "invalid_signature"
    message = "The webhook signature is invalid."


@dataclass(frozen=True)
class PaymentInitiation:
    provider_order_id: str
    client_payload: dict[str, Any]          # public values the app needs to open the provider's checkout (no secrets)


@dataclass(frozen=True)
class WebhookEvent:
    event_id: str                            # unique per provider event; used for duplicate protection
    event_type: str                          # one of PAYMENT_EVENTS
    provider_order_id: str | None = None
    provider_payment_id: str | None = None
    provider_refund_id: str | None = None
    amount: Decimal | None = None
    currency: str | None = None
    failure_reason: str | None = None


@dataclass(frozen=True)
class ProviderRefund:
    provider_refund_id: str
    status: str                              # "processed" | "pending"


@dataclass(frozen=True)
class ProviderPaymentState:
    status: str                              # canonical: "succeeded" | "failed" | "processing" | "cancelled" | "pending"
    provider_payment_id: str | None
    amount: Decimal | None
    currency: str | None
    failure_reason: str | None = None


class PaymentProvider(Protocol):
    name: str

    def is_configured(self) -> bool: ...

    def create_payment(self, *, reference: str, amount: Decimal, currency: str, customer_id: str, description: str) -> PaymentInitiation: ...

    def client_payload(self, *, provider_order_id: str, amount: Decimal, currency: str) -> dict[str, Any]: ...

    def parse_webhook(self, headers: Mapping[str, str], body: bytes) -> list[WebhookEvent]: ...

    def refund(self, *, provider_payment_id: str, amount: Decimal, currency: str, reference: str) -> ProviderRefund: ...

    def fetch_payment(self, *, provider_order_id: str) -> ProviderPaymentState: ...


def verify_hmac_sha256(secret: str, body: bytes, signature: str) -> bool:
    """Constant-time check of a hex HMAC-SHA256 signature over the RAW request body (helper for adapters)."""
    if not secret or not signature:
        return False
    expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature.strip().lower())


class UnconfiguredProvider:
    """Used while no provider is configured: every operation fails loudly instead of simulating success."""

    name = ""

    def is_configured(self) -> bool:
        return False

    def _fail(self, *_a, **_k):
        raise PaymentProviderNotConfigured()

    create_payment = client_payload = parse_webhook = refund = fetch_payment = _fail
