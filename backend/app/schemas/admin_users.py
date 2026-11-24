"""Admin console: customers, vendors, dashboard. Request models reject unknown fields (role / verification fields can never be injected)."""
from __future__ import annotations

from datetime import date, datetime
from enum import Enum
from typing import Annotated, Any
from uuid import UUID

from pydantic import BaseModel, StringConstraints

from app.schemas.common import Money, StrictModel

Reason = Annotated[str, StringConstraints(min_length=3, max_length=500)]


class AccountStatus(str, Enum):
    active = "active"
    inactive = "inactive"
    restricted = "restricted"


class AccountStatusChange(StrictModel):
    status: AccountStatus
    reason: Reason | None = None            # required (3+ chars) unless re-activating


class VendorApprove(StrictModel):
    note: Annotated[str, StringConstraints(max_length=500)] | None = None


class VendorReject(StrictModel):
    reason: Reason                          # shown to the vendor


class VendorSuspend(StrictModel):
    reason: Reason                          # shown to the vendor


class AuditEntry(BaseModel):
    at: datetime
    action: str
    actor_id: UUID | None
    details: dict[str, Any]


class AdminCustomerListItem(BaseModel):
    id: UUID
    full_name: str | None
    email: str | None
    phone: str | None
    status: str
    created_at: datetime
    order_count: int | None = None
    booking_count: int | None = None


class AdminCustomerDetail(AdminCustomerListItem):
    updated_at: datetime
    addresses: list[dict[str, Any]]
    activity: list[AuditEntry]              # administrative actions taken on this account


class AdminVendorListItem(BaseModel):
    id: UUID                                 # vendor_profiles.id (used by orders/products/bookings filters)
    user_id: UUID
    business_name: str
    owner_name: str | None
    owner_email: str | None
    contact_phone: str
    contact_email: str | None
    business_types: list[str]
    city: str
    state: str
    verification_status: str
    account_status: str | None
    created_at: datetime
    product_count: int | None = None
    order_count: int | None = None
    booking_count: int | None = None


class AdminVendorDetail(AdminVendorListItem):
    owner_phone: str | None
    description: str | None
    address_line1: str
    address_line2: str | None
    postal_code: str
    operating_hours: dict[str, Any]
    shop_image_paths: list[str]
    shop_image_urls: list[str]
    service_area_postal_codes: list[str]
    service_radius_km: float | None
    pickup_available: bool
    rejection_reason: str | None
    review_notes: str | None
    reviewed_by: UUID | None
    reviewed_at: datetime | None
    updated_at: datetime
    activity: list[AuditEntry]


# ---------------- dashboard
class DayCount(BaseModel):
    day: date
    count: int


class DayOrders(DayCount):
    value: Money                             # order value that day, excluding cancelled orders


class DashCustomers(BaseModel):
    total: int
    by_status: dict[str, int]
    new_in_period: int


class DashVendors(BaseModel):
    total: int
    by_verification: dict[str, int]
    by_account_status: dict[str, int]
    new_in_period: int


class DashOrders(BaseModel):
    total: int
    by_status: dict[str, int]
    value_completed: Money                   # sum of total_amount of completed orders
    value_confirmed: Money                   # confirmed, not yet completed


class DashBookings(BaseModel):
    total: int
    by_status: dict[str, int]


class DashSeries(BaseModel):
    orders: list[DayOrders]
    bookings: list[DayCount]
    customers: list[DayCount]
    vendors: list[DayCount]


class AdminDashboard(BaseModel):
    period: dict[str, date]
    customers: DashCustomers
    vendors: DashVendors
    orders: DashOrders
    bookings: DashBookings
    series: DashSeries
