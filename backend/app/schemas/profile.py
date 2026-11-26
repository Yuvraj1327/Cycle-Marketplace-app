from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo

from pydantic import BaseModel, Field, StringConstraints, field_validator

from app.schemas.common import StrictModel

Phone = Annotated[str, StringConstraints(pattern=r"^\+?[0-9]{7,15}$")]


class Preferences(StrictModel):
    """Display preferences saved on the account (the currency is fixed to INR platform-wide, so it is not stored). Every field is optional; the client falls back to its defaults for what is missing."""

    theme: Literal["light", "dark", "system"] | None = None
    timezone: Annotated[str, StringConstraints(min_length=1, max_length=64)] | None = None
    date_format: Literal["D MMM YYYY", "DD/MM/YYYY", "MM/DD/YYYY", "YYYY-MM-DD"] | None = None

    @field_validator("timezone")
    @classmethod
    def _known_timezone(cls, v: str | None) -> str | None:
        if v is None:
            return v
        try:
            ZoneInfo(v)
        except (KeyError, ValueError, OSError):  # unknown key: ZoneInfoNotFoundError (a KeyError); malformed key: ValueError
            raise ValueError("Unknown time zone.") from None
        return v


class ProfileResponse(BaseModel):
    id: UUID
    full_name: str
    email: str | None
    phone: str | None
    role: str
    status: str
    avatar_path: str | None
    preferences: dict = Field(default_factory=dict)
    created_at: datetime
    updated_at: datetime


class ProfileUpdate(StrictModel):
    """Only these fields are editable. Email, role and status are deliberately absent (extra fields => 422)."""

    full_name: Annotated[str, StringConstraints(min_length=1, max_length=120)] | None = None
    phone: Phone | None = None
    avatar_path: Annotated[str, StringConstraints(min_length=3, max_length=300)] | None = None
    preferences: Preferences | None = None
