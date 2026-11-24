import re
from datetime import datetime
from enum import Enum
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, StringConstraints, model_validator

from app.schemas.common import StrictModel
from app.schemas.profile import Phone

Text = Annotated[str, StringConstraints(min_length=1, max_length=200)]


class AddressType(str, Enum):
    delivery = "delivery"
    pickup = "pickup"
    both = "both"


def _check_postal(country: str, postal: str) -> None:
    if country.strip().lower() == "india":
        if not re.fullmatch(r"[1-9][0-9]{5}", postal):
            raise ValueError("postal_code must be a valid 6-digit Indian PIN code")
    elif not re.fullmatch(r"[A-Za-z0-9 \-]{3,10}", postal):
        raise ValueError("postal_code is invalid")


class AddressCreate(StrictModel):
    label: Annotated[str, StringConstraints(max_length=50)] | None = None
    address_type: AddressType = AddressType.both
    recipient_name: Annotated[str, StringConstraints(min_length=1, max_length=120)]
    phone: Phone
    address_line1: Text
    address_line2: Annotated[str, StringConstraints(max_length=200)] | None = None
    landmark: Annotated[str, StringConstraints(max_length=200)] | None = None
    city: Annotated[str, StringConstraints(min_length=1, max_length=100)]
    state: Annotated[str, StringConstraints(min_length=1, max_length=100)]
    postal_code: str
    country: Annotated[str, StringConstraints(min_length=2, max_length=100)] = "India"
    is_default: bool = False

    @model_validator(mode="after")
    def _postal(self):
        _check_postal(self.country, self.postal_code)
        return self


class AddressUpdate(StrictModel):
    """Partial update (only supplied fields change). Use PATCH .../default to change the default address."""

    label: Annotated[str, StringConstraints(max_length=50)] | None = None
    address_type: AddressType | None = None
    recipient_name: Annotated[str, StringConstraints(min_length=1, max_length=120)] | None = None
    phone: Phone | None = None
    address_line1: Text | None = None
    address_line2: Annotated[str, StringConstraints(max_length=200)] | None = None
    landmark: Annotated[str, StringConstraints(max_length=200)] | None = None
    city: Annotated[str, StringConstraints(min_length=1, max_length=100)] | None = None
    state: Annotated[str, StringConstraints(min_length=1, max_length=100)] | None = None
    postal_code: str | None = None
    country: Annotated[str, StringConstraints(min_length=2, max_length=100)] | None = None


class AddressResponse(BaseModel):
    id: UUID
    label: str | None
    address_type: AddressType
    recipient_name: str
    phone: str
    address_line1: str
    address_line2: str | None
    landmark: str | None
    city: str
    state: str
    postal_code: str
    country: str
    is_default: bool
    created_at: datetime
    updated_at: datetime
