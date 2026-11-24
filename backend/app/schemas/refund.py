from datetime import datetime
from enum import Enum
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, Field, StringConstraints, model_validator

from app.schemas.common import Money, StrictModel
from app.schemas.order import Reason
from app.schemas.product import MoneyIn


class RefundStatus(str, Enum):
    requested = "requested"
    approved = "approved"
    processed = "processed"
    rejected = "rejected"
    failed = "failed"


class RefundOut(BaseModel):
    id: UUID
    payment_id: UUID
    order_id: UUID | None
    vendor_order_id: UUID | None
    amount: Money
    reason: str | None
    status: RefundStatus
    provider: str | None
    provider_refund_id: str | None
    failure_reason: str | None
    requested_by: UUID | None
    processed_by: UUID | None
    processed_at: datetime | None
    created_at: datetime


class RefundCreate(StrictModel):
    payment_id: UUID
    amount: MoneyIn = Field(gt=0)
    reason: Reason
    vendor_order_id: UUID | None = None


class RefundAction(StrictModel):
    """approve | reject | process | fail.
    `process` asks the payment provider to refund (real provider required). `manual=true` instead records a refund the
    finance team already paid outside the system and requires the payment reference."""

    action: str = Field(pattern="^(approve|reject|process|fail)$")
    manual: bool = False
    provider_refund_id: Annotated[str, StringConstraints(min_length=3, max_length=100)] | None = None
    note: Annotated[str, StringConstraints(max_length=500)] | None = None

    @model_validator(mode="after")
    def _rules(self):
        if self.action == "process" and self.manual and not self.provider_refund_id:
            raise ValueError("provider_refund_id (the external payment reference) is required for a manual refund")
        if self.action in ("reject", "fail") and not (self.note or "").strip():
            raise ValueError("note is required when rejecting or failing a refund")
        return self
