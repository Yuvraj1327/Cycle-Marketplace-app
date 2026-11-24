from datetime import date, datetime
from typing import Annotated, Any
from uuid import UUID

from pydantic import BaseModel, Field, StringConstraints, field_validator

from app.schemas.category import ImagePath, Slug
from app.schemas.common import Money, StrictModel
from app.schemas.product import MoneyIn

DAY_KEYS = {"mon", "tue", "wed", "thu", "fri", "sat", "sun"}


class ServiceCategoryOut(BaseModel):
    id: UUID
    name: str
    slug: str
    description: str | None
    image_url: str | None
    sort_order: int
    service_count: int | None = None


class ServiceCategoryDetail(ServiceCategoryOut):
    services: list["ServiceOut"] = []


class AdminServiceCategoryOut(ServiceCategoryOut):
    is_active: bool
    image_path: str | None
    booking_count: int | None = None
    created_at: datetime
    updated_at: datetime


class ServiceCategoryCreate(StrictModel):
    name: Annotated[str, StringConstraints(min_length=2, max_length=100)]
    slug: Slug | None = None
    description: Annotated[str, StringConstraints(max_length=1000)] | None = None
    image_path: ImagePath | None = None    # object in the public `banners` bucket (admin-writable)
    sort_order: int = 0
    is_active: bool = True


class ServiceCategoryUpdate(StrictModel):
    name: Annotated[str, StringConstraints(min_length=2, max_length=100)] | None = None
    slug: Slug | None = None
    description: Annotated[str, StringConstraints(max_length=1000)] | None = None
    image_path: ImagePath | None = None
    sort_order: int | None = None
    is_active: bool | None = None


def _days(v):
    if v is None:
        return v
    if not set(v) <= DAY_KEYS or len(set(v)) != len(v):
        raise ValueError(f"available_days must be unique values from {sorted(DAY_KEYS)}")
    return v


Name = Annotated[str, StringConstraints(min_length=2, max_length=150)]
Desc = Annotated[str, StringConstraints(max_length=2000)]
Minutes = Annotated[int, Field(ge=1, le=1440)]
SlotMinutes = Annotated[int, Field(ge=15, le=240, multiple_of=5)]
Capacity = Annotated[int, Field(ge=1, le=20)]


class ServiceCreate(StrictModel):
    """The vendor comes from the session. The category must be an existing, active platform category."""

    service_category_id: UUID
    name: Name
    description: Desc | None = None
    price: MoneyIn
    estimated_duration_minutes: Minutes | None = None
    is_available: bool = True
    available_days: list[str] | None = Field(None, description="Weekdays (mon..sun) this service is offered. Null = every day the business is open.")
    slot_minutes: SlotMinutes = 60
    max_bookings_per_slot: Capacity = 1

    _d = field_validator("available_days")(_days)


class ServiceReplace(ServiceCreate):
    is_active: bool = True


class ServicePatch(StrictModel):
    service_category_id: UUID | None = None
    name: Name | None = None
    description: Desc | None = None
    price: MoneyIn | None = None
    estimated_duration_minutes: Minutes | None = None
    is_available: bool | None = None
    is_active: bool | None = None
    available_days: list[str] | None = None
    slot_minutes: SlotMinutes | None = None
    max_bookings_per_slot: Capacity | None = None

    _d = field_validator("available_days")(_days)


class ProviderOut(BaseModel):
    """Public provider summary: no street address, phone or e-mail."""

    id: UUID
    business_name: str
    city: str | None = None
    state: str | None = None
    pickup_available: bool = False
    service_area_postal_codes: list[str] = []
    service_radius_km: float | None = None
    operating_hours: dict[str, Any] = {}


class CategoryRef(BaseModel):
    id: UUID
    name: str
    slug: str


class ServiceOut(BaseModel):
    id: UUID
    name: str
    description: str | None
    price: Money
    estimated_duration_minutes: int | None
    is_available: bool
    available_days: list[str] | None
    slot_minutes: int
    category: CategoryRef | None
    provider: ProviderOut | None
    created_at: datetime


class VendorServiceOut(BaseModel):
    id: UUID
    service_category_id: UUID
    category: CategoryRef | None
    name: str
    description: str | None
    price: Money
    estimated_duration_minutes: int | None
    is_active: bool
    is_available: bool
    available_days: list[str] | None
    slot_minutes: int
    max_bookings_per_slot: int
    created_at: datetime
    updated_at: datetime


class AdminServiceOut(VendorServiceOut):
    vendor_id: UUID
    vendor_name: str | None = None
    vendor_status: str | None = None


class SlotOut(BaseModel):
    start: str
    end: str
    capacity: int
    booked: int
    available: bool


class AvailabilityOut(BaseModel):
    service_id: UUID
    date: date
    bookable: bool
    reason: str | None
    slot_minutes: int
    slots: list[SlotOut]


class DeleteResult(BaseModel):
    result: str
    detail: str

