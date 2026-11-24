from datetime import datetime
from enum import Enum
from typing import Annotated, Any
from uuid import UUID

from pydantic import BaseModel, StringConstraints

from app.schemas.common import Money, StrictModel


class OrderStatus(str, Enum):
    pending = "pending"
    confirmed = "confirmed"
    completed = "completed"
    cancelled = "cancelled"


class VendorOrderStatus(str, Enum):
    pending = "pending"
    accepted = "accepted"
    rejected = "rejected"
    preparing = "preparing"
    ready_for_dispatch = "ready_for_dispatch"
    out_for_delivery = "out_for_delivery"
    delivered = "delivered"
    cancelled = "cancelled"


class PaymentStatus(str, Enum):
    pending = "pending"
    processing = "processing"
    successful = "successful"
    failed = "failed"
    cancelled = "cancelled"
    refunded = "refunded"
    partially_refunded = "partially_refunded"


class PaymentMethod(str, Enum):
    online = "online"
    cod = "cod"


Reason = Annotated[str, StringConstraints(min_length=3, max_length=500)]


class OrderItemOut(BaseModel):
    id: UUID
    product_id: UUID | None
    product_name: str
    product_brand: str | None
    product_model: str | None
    product_condition: str | None
    image_url: str | None
    unit_price: Money
    quantity: int
    line_total: Money


class VendorOrderOut(BaseModel):
    id: UUID
    vendor_order_number: str
    vendor_id: UUID
    vendor_name: str | None
    status: VendorOrderStatus
    subtotal: Money
    delivery_charge: Money
    discount_amount: Money
    total_amount: Money
    accepted_at: datetime | None
    delivered_at: datetime | None
    rejection_reason: str | None
    cancellation_reason: str | None
    items: list[OrderItemOut]


class OrderSummaryOut(BaseModel):
    id: UUID
    order_number: str
    status: OrderStatus
    payment_method: PaymentMethod
    payment_status: PaymentStatus
    subtotal: Money
    delivery_charge: Money
    discount_amount: Money
    total_amount: Money
    item_count: int
    vendor_count: int
    created_at: datetime
    cancelled_reason: str | None


class OrderDetailOut(OrderSummaryOut):
    delivery_address: dict[str, Any]
    coupon_code: str | None
    customer_note: str | None
    payment_due_at: datetime | None
    cancelled_at: datetime | None
    can_cancel: bool
    vendor_orders: list[VendorOrderOut]


class TimelineEvent(BaseModel):
    at: datetime
    scope: str                       # "order" | "vendor_order"
    vendor_order_id: UUID | None
    vendor_name: str | None
    from_status: str | None
    to_status: str
    note: str | None


class TrackingOut(BaseModel):
    order_id: UUID
    order_number: str
    status: OrderStatus
    payment_status: PaymentStatus
    vendor_orders: list[dict[str, Any]]
    timeline: list[TimelineEvent]


class CancelRequest(StrictModel):
    reason: Reason


# ---------------- vendor side
class VendorOrderListItem(BaseModel):
    id: UUID
    vendor_order_number: str
    order_id: UUID
    order_number: str
    status: VendorOrderStatus
    payment_method: PaymentMethod
    payment_status: PaymentStatus
    subtotal: Money
    total_amount: Money
    commission_amount: Money | None
    item_count: int
    placed_at: datetime


class VendorOrderDetail(VendorOrderListItem):
    delivery_charge: Money
    discount_amount: Money
    net_payable: Money                # subtotal - commission (before any later deductions)
    delivery_address: dict[str, Any]
    customer_note: str | None
    accepted_at: datetime | None
    delivered_at: datetime | None
    vendor_note: str | None
    rejection_reason: str | None
    cancellation_reason: str | None
    items: list[OrderItemOut]


class VendorAccept(StrictModel):
    note: Annotated[str, StringConstraints(max_length=500)] | None = None


class VendorReject(StrictModel):
    reason: Reason


class VendorStatusUpdate(StrictModel):
    """Fulfilment steps. `cancelled` needs a reason; rejecting a pending order uses /reject."""

    status: VendorOrderStatus
    note: Annotated[str, StringConstraints(max_length=500)] | None = None


# ---------------- admin
class AdminCustomerOut(BaseModel):
    id: UUID
    full_name: str | None
    email: str | None
    phone: str | None


class AdminOrderOut(OrderDetailOut):
    customer: AdminCustomerOut | None
    payments: list[dict[str, Any]]
    refunds: list[dict[str, Any]]
    cancelled_by_role: str | None = None


class AdminStatusUpdate(StrictModel):
    """Parent orders can only be CANCELLED by an admin (their status is otherwise derived from vendor orders).
    With `vendor_order_id` the change applies to that vendor order and follows the vendor state machine."""

    status: str
    reason: Reason | None = None
    vendor_order_id: UUID | None = None
