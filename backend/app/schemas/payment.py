from datetime import datetime
from typing import Annotated, Any
from uuid import UUID

from pydantic import BaseModel, StringConstraints

from app.schemas.common import Money, StrictModel
from app.schemas.order import PaymentMethod, PaymentStatus


class PaymentOut(BaseModel):
    id: UUID
    order_id: UUID | None
    method: PaymentMethod
    provider: str | None
    provider_order_id: str | None
    status: PaymentStatus
    amount: Money
    currency: str
    amount_due: Money                  # still to be paid (COD: cash outstanding)
    refunded_amount: Money
    paid_at: datetime | None
    failure_reason: str | None
    created_at: datetime


class PaymentWithPayload(PaymentOut):
    client_payload: dict[str, Any] | None = None   # public values for the provider's checkout widget (never secrets)


class PaymentCreate(StrictModel):
    order_id: UUID


class WebhookAck(BaseModel):
    received: int
    results: list[dict[str, str]]


class AdminPaymentOut(PaymentOut):
    customer_id: UUID
    needs_review: bool
    review_reason: str | None
    recorded_by: UUID | None
    provider_payment_id: str | None


class AdminPaymentDetail(AdminPaymentOut):
    order: dict[str, Any] | None
    events: list[dict[str, Any]]
    refunds: list[dict[str, Any]]


class RevenueSummary(BaseModel):
    period_from: datetime
    period_to: datetime
    collected: Money
    refunded: Money
    net_collected: Money
    commission_earned: Money
    cod_outstanding: Money
    orders_placed: int
    orders_completed: int
    settlements: dict[str, Any]


Note = Annotated[str, StringConstraints(max_length=500)]
