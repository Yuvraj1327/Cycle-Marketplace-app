from datetime import datetime
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, StringConstraints

from app.schemas.common import Money, StrictModel


class SettlementOut(BaseModel):
    id: UUID
    vendor_id: UUID
    vendor_order_id: UUID
    order_number: str | None = None
    gross_amount: Money
    commission_amount: Money
    deductions_amount: Money
    net_amount: Money
    status: str            # pending (awaiting confirmed payment) | ready | paid (recorded manually) | cancelled
    payout_reference: str | None
    settled_at: datetime | None
    created_at: datetime


class SettlementSummary(BaseModel):
    total: int
    by_status: dict[str, dict[str, Money]]


class SettlementPage(BaseModel):
    items: list[SettlementOut]
    total: int
    page: int
    limit: int
    pages: int
    summary: dict[str, Money]


class MarkPaid(StrictModel):
    """Records that the vendor was paid OUTSIDE this system. The platform does not move money."""

    payout_reference: Annotated[str, StringConstraints(min_length=3, max_length=100)]
    notes: Annotated[str, StringConstraints(max_length=500)] | None = None
