"""Step 10: admin console operations - coupons, announcements, reports, fulfilment overview, audit trail."""
from datetime import datetime
from decimal import Decimal
from enum import Enum
from typing import Annotated, Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field, StringConstraints, model_validator

from app.schemas.common import Money, StrictModel
from app.schemas.order import PaymentMethod, PaymentStatus, VendorOrderStatus

CouponCode = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{3,30}$")]
Amount = Annotated[Decimal, Field(max_digits=12, decimal_places=2)]


# ---------------------------------------------------------------- coupons
class CouponCreate(StrictModel):
    """Coupons are redeemed at product checkout only. Service-booking coupons are not supported (bookings take no payment yet), so `applies_to` is
    `products` or `all` (both are honoured identically today)."""

    code: CouponCode
    description: Annotated[str, StringConstraints(max_length=300)] | None = None
    discount_type: Literal["percentage", "fixed"]
    discount_value: Amount = Field(gt=0)
    max_discount_amount: Amount | None = Field(None, ge=0)
    min_order_amount: Amount = Field(Decimal("0"), ge=0)
    applies_to: Literal["products", "all"] = "all"
    valid_from: datetime | None = None
    valid_until: datetime | None = None
    usage_limit: int | None = Field(None, gt=0, le=10_000_000)
    per_user_limit: int | None = Field(None, gt=0, le=10_000)
    is_active: bool = True

    @model_validator(mode="after")
    def _rules(self):
        if self.discount_type == "percentage" and self.discount_value > 100:
            raise ValueError("a percentage discount cannot exceed 100")
        if self.discount_type == "fixed" and self.max_discount_amount is not None:
            raise ValueError("max_discount_amount only applies to percentage coupons")
        if self.valid_from and self.valid_until and self.valid_until <= self.valid_from:
            raise ValueError("valid_until must be after valid_from")
        return self


class CouponUpdate(StrictModel):
    """Partial update. `code` may only change while the coupon has never been used (past orders keep the code they used)."""

    code: CouponCode | None = None
    description: Annotated[str, StringConstraints(max_length=300)] | None = None
    discount_type: Literal["percentage", "fixed"] | None = None
    discount_value: Amount | None = Field(None, gt=0)
    max_discount_amount: Amount | None = Field(None, ge=0)
    min_order_amount: Amount | None = Field(None, ge=0)
    applies_to: Literal["products", "all"] | None = None
    valid_from: datetime | None = None
    valid_until: datetime | None = None
    usage_limit: int | None = Field(None, gt=0, le=10_000_000)
    per_user_limit: int | None = Field(None, gt=0, le=10_000)
    is_active: bool | None = None


class CouponOut(BaseModel):
    id: UUID
    code: str
    description: str | None
    discount_type: str
    discount_value: Money
    max_discount_amount: Money | None
    min_order_amount: Money
    applies_to: str
    valid_from: datetime
    valid_until: datetime | None
    usage_limit: int | None
    per_user_limit: int | None
    used_count: int
    is_active: bool
    state: str                       # active | inactive | scheduled | expired | exhausted  (derived now; see service)
    created_at: datetime
    updated_at: datetime


# ---------------------------------------------------------------- announcements / notifications
class AnnouncementType(str, Enum):
    promotion = "promotion"
    announcement = "announcement"
    system = "system"


class Audience(str, Enum):
    customers = "customers"
    vendors = "vendors"
    specific = "specific"


class AnnouncementCreate(StrictModel):
    """`customers` / `vendors` = every ACTIVE account of that role. `specific` = the listed users (customers or vendors; max 200)."""

    title: Annotated[str, StringConstraints(min_length=3, max_length=150)]
    message: Annotated[str, StringConstraints(min_length=3, max_length=2000)]
    type: AnnouncementType = AnnouncementType.announcement
    audience: Audience
    user_ids: Annotated[list[UUID], Field(max_length=200)] | None = None

    @model_validator(mode="after")
    def _audience(self):
        if self.audience == Audience.specific and not self.user_ids:
            raise ValueError("choose at least one recipient for a specific audience")
        if self.audience != Audience.specific and self.user_ids:
            raise ValueError("user_ids is only for a specific audience")
        return self


class AnnouncementOut(BaseModel):
    id: UUID
    title: str
    message: str
    type: AnnouncementType
    audience: Audience
    recipient_count: int
    delivered: int                   # in-app notification rows that exist
    read: int
    push_sent: int = 0               # devices reached (a recipient with no device or an invalid token is not a failure)
    push_failed: int = 0
    push_pending: int = 0
    created_by: UUID | None
    created_by_name: str | None
    created_at: datetime
    channel: str = "in_app"          # push delivery is not part of the backend yet


class AdminNotificationOut(BaseModel):
    id: UUID
    user_id: UUID
    recipient_name: str | None
    recipient_role: str | None
    type: str
    title: str
    message: str
    related_type: str | None
    related_id: UUID | None
    is_read: bool
    announcement_id: UUID | None
    created_at: datetime
    channel: str = "in_app"
    push_status: str = "skipped"     # pending | sending | sent | failed | skipped | expired
    push_error: str | None = None


# ---------------------------------------------------------------- fulfilment overview
class AdminVendorOrderItem(BaseModel):
    id: UUID
    vendor_order_number: str
    order_id: UUID
    order_number: str | None
    vendor_id: UUID
    vendor_name: str | None
    customer_id: UUID | None
    customer_name: str | None
    status: VendorOrderStatus
    order_status: str | None
    payment_method: PaymentMethod | None
    payment_status: PaymentStatus | None
    delivery_city: str | None
    delivery_postal_code: str | None
    item_count: int
    subtotal: Money
    total_amount: Money
    commission_amount: Money | None
    accepted_at: datetime | None
    delivered_at: datetime | None
    created_at: datetime


# ---------------------------------------------------------------- reports
class ReportKind(str, Enum):
    orders = "orders"
    sales = "sales"
    vendors = "vendors"
    customers = "customers"
    services = "services"
    payments = "payments"


class ReportOut(BaseModel):
    kind: ReportKind
    period_from: str
    period_to: str
    timezone: str = "Asia/Kolkata"
    data: dict[str, Any]


# ---------------------------------------------------------------- audit trail / status
class AuditOut(BaseModel):
    id: UUID
    actor_id: UUID | None
    actor_name: str | None
    actor_role: str | None
    action: str
    entity_type: str
    entity_id: UUID | None
    details: dict[str, Any]
    created_at: datetime


class ServiceStatusUpdate(StrictModel):
    is_active: bool
    reason: Annotated[str, StringConstraints(max_length=500)] | None = None

    @model_validator(mode="after")
    def _reason(self):
        if not self.is_active and len((self.reason or "").strip()) < 3:
            raise ValueError("a reason is required to deactivate a service")
        return self


class PaymentProviderInfo(BaseModel):
    """Whether a payment provider is configured server-side. Never any credential."""

    configured: bool
    provider: str | None
    refunds_via_provider: bool


class AdminTimelineEvent(BaseModel):
    """One status change of an order / vendor order / service booking, with who made it (from the existing history tables)."""

    at: datetime
    scope: Literal["order", "vendor_order", "booking"]
    vendor_order_id: UUID | None = None
    vendor_name: str | None = None
    from_status: str | None
    to_status: str
    note: str | None
    changed_by_id: UUID | None = None
    changed_by_name: str | None = None
    changed_by_role: str | None = None
