from datetime import date, datetime
from decimal import Decimal
from enum import Enum
from typing import Annotated, Any
from uuid import UUID

from pydantic import BaseModel, Field, StringConstraints, model_validator

from app.schemas.common import Money, StrictModel

HHMM = Annotated[str, StringConstraints(pattern=r"^([01][0-9]|2[0-3]):[0-5][0-9]$")]
Reason = Annotated[str, StringConstraints(min_length=3, max_length=500)]


class BookingStatus(str, Enum):
    pending = "pending"
    accepted = "accepted"
    rejected = "rejected"
    picked_up = "picked_up"
    in_service = "in_service"
    ready_for_delivery = "ready_for_delivery"
    completed = "completed"
    cancelled = "cancelled"


class BookingCreate(StrictModel):
    """Customer and vendor come from the session / the chosen service; the price comes from the database."""

    service_id: UUID
    cycle_brand: Annotated[str, StringConstraints(max_length=100)] | None = None
    cycle_model: Annotated[str, StringConstraints(max_length=100)] | None = None
    cycle_details: Annotated[str, StringConstraints(max_length=500)] | None = Field(None, description="Type / size / colour / anything identifying the cycle")
    issue_description: Annotated[str, StringConstraints(min_length=10, max_length=2000)]
    preferred_date: date
    slot_start: HHMM = Field(description="Start of the chosen slot, exactly as returned by GET /services/{id}/availability")
    needs_pickup_dropoff: bool = False
    pickup_address_id: UUID | None = None
    dropoff_address_id: UUID | None = Field(None, description="Defaults to the pickup address")
    pickup_instructions: Annotated[str, StringConstraints(max_length=500)] | None = None

    @model_validator(mode="after")
    def _pickup(self):
        if self.needs_pickup_dropoff and not self.pickup_address_id:
            raise ValueError("pickup_address_id is required for doorstep pickup")
        if not self.needs_pickup_dropoff and (self.pickup_address_id or self.dropoff_address_id or self.pickup_instructions):
            raise ValueError("address and instruction fields are only for doorstep pickup/drop-off")
        return self


class CancelBooking(StrictModel):
    reason: Reason


class ImageRegister(StrictModel):
    storage_path: Annotated[str, StringConstraints(min_length=10, max_length=300)]


class BookingImageOut(BaseModel):
    id: UUID
    storage_path: str
    url: str | None            # short-lived signed URL (private bucket); null if the viewer may not read it


class Pickup(BaseModel):
    id: UUID
    pickup_address: dict[str, Any]
    dropoff_address: dict[str, Any]
    pickup_status: str          # database value: pending | scheduled | completed | failed | cancelled
    pickup_stage: str           # friendly: requested | scheduled | picked_up | failed | cancelled
    delivery_status: str
    delivery_stage: str         # requested | scheduled | delivered | failed | cancelled
    scheduled_pickup_at: datetime | None
    scheduled_delivery_at: datetime | None
    picked_up_at: datetime | None
    delivered_at: datetime | None
    pickup_charge: Money
    dropoff_charge: Money
    customer_instructions: str | None
    notes: str | None


class Pricing(BaseModel):
    estimated_price: Money               # quoted when booked; never overwritten
    additional_charges_total: Money
    current_price: Money                 # estimate + additional charges (what the vendor currently expects for the work)
    pickup_charge: Money
    dropoff_charge: Money
    total_estimated: Money               # estimate + pickup + drop-off
    total_current: Money                 # current price + pickup + drop-off
    logistics_charges_configured: bool | None = None   # false => the platform has no pickup/drop-off charge configured (recorded as 0)
    note: str = "No payment is taken here. Whether customers must approve additional charges is pending a client decision."


class Schedule(BaseModel):
    date: date | None
    slot_start: str | None
    slot_end: str | None


class Charge(BaseModel):
    id: UUID
    amount: Money
    reason: str
    recorded_role: str | None
    created_at: datetime


class Note(BaseModel):
    id: UUID
    author_role: str
    note: str
    created_at: datetime


class BookingSummary(BaseModel):
    id: UUID
    booking_number: str
    status: BookingStatus
    service_name: str
    vendor_name: str | None
    preferred: Schedule
    confirmed: Schedule
    needs_pickup_dropoff: bool
    current_price: Money
    created_at: datetime


class BookingDetail(BookingSummary):
    service_id: UUID | None
    service_category: dict[str, Any] | None
    vendor: dict[str, Any] | None
    cycle: dict[str, Any]
    issue_description: str
    estimated_duration_minutes: int | None
    pricing: Pricing
    pickup: Pickup | None
    charges: list[Charge]
    notes: list[Note]
    images: list[BookingImageOut]
    rejection_reason: str | None
    cancellation_reason: str | None
    completion_notes: str | None
    accepted_at: datetime | None
    completed_at: datetime | None
    can_cancel: bool


class TimelineEvent(BaseModel):
    at: datetime
    from_status: str | None
    to_status: str
    note: str | None
    by_role: str | None = None


class Tracking(BaseModel):
    booking_id: UUID
    booking_number: str
    status: BookingStatus
    preferred: Schedule
    confirmed: Schedule
    pickup: Pickup | None
    estimated_duration_minutes: int | None
    pricing: Pricing
    timeline: list[TimelineEvent]
    charges: list[Charge]
    notes: list[Note]
    completed_at: datetime | None
    completion_notes: str | None


# ---------------- vendor / admin
class CustomerBrief(BaseModel):
    full_name: str | None
    phone: str | None


class VendorBookingDetail(BookingDetail):
    customer: CustomerBrief | None


class AdminBookingDetail(VendorBookingDetail):
    vendor_admin: dict[str, Any] | None
    customer_id: UUID


class AcceptBooking(StrictModel):
    """Optionally confirm a different slot than the customer preferred."""

    confirmed_date: date | None = None
    slot_start: HHMM | None = None
    note: Annotated[str, StringConstraints(max_length=500)] | None = None

    @model_validator(mode="after")
    def _both(self):
        if (self.confirmed_date is None) != (self.slot_start is None):
            raise ValueError("send confirmed_date and slot_start together (or neither to confirm the preferred slot)")
        return self


class RejectBooking(StrictModel):
    reason: Reason


class ScheduleChange(StrictModel):
    confirmed_date: date
    slot_start: HHMM
    note: Annotated[str, StringConstraints(max_length=500)] | None = None


class StatusUpdate(StrictModel):
    """picked_up | in_service | ready_for_delivery | completed | cancelled (accept/reject have their own endpoints)."""

    status: BookingStatus
    note: Annotated[str, StringConstraints(max_length=500)] | None = None


class ChargeCreate(StrictModel):
    """Positive = additional charge; negative = correction/discount. Recorded separately; the original estimate is never changed."""

    amount: Annotated[Decimal, Field(ge=-1_000_000, le=1_000_000, max_digits=12, decimal_places=2)]
    reason: Reason

    @model_validator(mode="after")
    def _nonzero(self):
        if self.amount == 0:
            raise ValueError("the amount cannot be zero")
        return self


class NoteCreate(StrictModel):
    note: Annotated[str, StringConstraints(min_length=2, max_length=1000)]


class LogisticsStep(str, Enum):
    scheduled = "scheduled"
    failed = "failed"
    cancelled = "cancelled"


class LogisticsUpdate(StrictModel):
    """Coordination only. Completion is recorded by moving the booking to picked_up / completed."""

    scheduled_pickup_at: datetime | None = None
    scheduled_delivery_at: datetime | None = None
    pickup_status: LogisticsStep | None = None
    delivery_status: LogisticsStep | None = None
    notes: Annotated[str, StringConstraints(max_length=500)] | None = None

    @model_validator(mode="after")
    def _any(self):
        if not self.model_fields_set:
            raise ValueError("nothing to update")
        return self


class AdminStatusUpdate(StrictModel):
    status: BookingStatus
    reason: Annotated[str, StringConstraints(max_length=500)] | None = None


class PickupListItem(BaseModel):
    id: UUID
    booking_id: UUID
    booking_number: str | None
    booking_status: str | None
    service_name: str | None
    vendor_name: str | None
    customer: CustomerBrief | None
    pickup: Pickup
    preferred: Schedule



class VendorBookingListItem(BookingSummary):
    customer: CustomerBrief | None
    issue_description: str
    pickup_stage: str | None = None
    delivery_stage: str | None = None


class AdminBookingListItem(VendorBookingListItem):
    customer_id: UUID
    vendor_id: UUID


class BookingOptions(BaseModel):
    """Platform settings that shape the booking form. `*_charge` is null while the platform has not configured an amount."""

    pickup_charge: Money | None
    dropoff_charge: Money | None
    charges_configured: bool
    min_notice_hours: int
    max_advance_days: int
