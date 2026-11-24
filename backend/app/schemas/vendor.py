import re
from datetime import datetime
from enum import Enum
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field, StringConstraints, field_validator, model_validator

from app.schemas.common import StrictModel
from app.schemas.profile import Phone

WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
_HHMM = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")


class BusinessType(str, Enum):
    bicycle_shop = "bicycle_shop"
    used_cycle_seller = "used_cycle_seller"
    spare_parts_seller = "spare_parts_seller"
    service_provider = "service_provider"


class DayHours(StrictModel):
    closed: bool = False
    open: str | None = None
    close: str | None = None

    @model_validator(mode="after")
    def _times(self):
        if self.closed:
            return self
        if not (self.open and self.close and _HHMM.match(self.open) and _HHMM.match(self.close)):
            raise ValueError("open and close must be HH:MM unless the day is closed")
        if self.close <= self.open:
            raise ValueError("close must be after open")
        return self


def _check_hours(v: dict[str, DayHours] | None):
    if v is not None and not set(v) <= set(WEEKDAYS):
        raise ValueError(f"operating_hours keys must be among {WEEKDAYS}")
    return v


PostalCode = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9 \-]{3,10}$")]
ShortText = Annotated[str, StringConstraints(min_length=1, max_length=200)]


class VendorRegister(StrictModel):
    """Business application. Verification status is never client-supplied: new vendors are always 'pending'."""

    business_name: Annotated[str, StringConstraints(min_length=2, max_length=150)]
    business_types: Annotated[list[BusinessType], Field(min_length=1, max_length=4)]
    description: Annotated[str, StringConstraints(max_length=2000)] | None = None
    address_line1: ShortText
    address_line2: Annotated[str, StringConstraints(max_length=200)] | None = None
    city: Annotated[str, StringConstraints(min_length=1, max_length=100)]
    state: Annotated[str, StringConstraints(min_length=1, max_length=100)]
    postal_code: PostalCode
    contact_phone: Phone
    contact_email: EmailStr | None = None
    operating_hours: dict[str, DayHours] = Field(default_factory=dict)
    shop_image_paths: Annotated[list[Annotated[str, StringConstraints(min_length=3, max_length=300)]], Field(max_length=10)] = Field(default_factory=list)
    service_area_postal_codes: Annotated[list[PostalCode], Field(max_length=200)] = Field(default_factory=list)
    service_radius_km: Annotated[float, Field(ge=0, le=500)] | None = None
    pickup_available: bool = False

    _hours = field_validator("operating_hours")(_check_hours)

    @field_validator("business_types")
    @classmethod
    def _unique_types(cls, v):
        if len(set(v)) != len(v):
            raise ValueError("business_types must not contain duplicates")
        return v


class VendorUpdate(StrictModel):
    """Partial update of business information. Verification fields cannot be sent (extra fields => 422)."""

    business_name: Annotated[str, StringConstraints(min_length=2, max_length=150)] | None = None
    business_types: Annotated[list[BusinessType], Field(min_length=1, max_length=4)] | None = None
    description: Annotated[str, StringConstraints(max_length=2000)] | None = None
    address_line1: ShortText | None = None
    address_line2: Annotated[str, StringConstraints(max_length=200)] | None = None
    city: Annotated[str, StringConstraints(min_length=1, max_length=100)] | None = None
    state: Annotated[str, StringConstraints(min_length=1, max_length=100)] | None = None
    postal_code: PostalCode | None = None
    contact_phone: Phone | None = None
    contact_email: EmailStr | None = None
    operating_hours: dict[str, DayHours] | None = None
    shop_image_paths: Annotated[list[Annotated[str, StringConstraints(min_length=3, max_length=300)]], Field(max_length=10)] | None = None
    service_area_postal_codes: Annotated[list[PostalCode], Field(max_length=200)] | None = None
    service_radius_km: Annotated[float, Field(ge=0, le=500)] | None = None
    pickup_available: bool | None = None

    _hours = field_validator("operating_hours")(_check_hours)


class VendorProfileResponse(BaseModel):
    """Owner's view. Internal admin fields (review_notes, reviewed_by) are intentionally not exposed."""

    id: UUID
    business_name: str
    business_types: list[BusinessType]
    description: str | None
    address_line1: str
    address_line2: str | None
    city: str
    state: str
    postal_code: str
    contact_phone: str
    contact_email: str | None
    operating_hours: dict
    shop_image_paths: list[str]
    service_area_postal_codes: list[str]
    service_radius_km: float | None
    pickup_available: bool
    verification_status: str
    rejection_reason: str | None
    reviewed_at: datetime | None
    created_at: datetime
    updated_at: datetime


class VendorStatusResponse(BaseModel):
    verification_status: str
    rejection_reason: str | None
    reviewed_at: datetime | None
    can_operate: bool
