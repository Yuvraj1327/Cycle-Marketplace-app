from datetime import datetime
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, StringConstraints

from app.schemas.common import StrictModel

Phone = Annotated[str, StringConstraints(pattern=r"^\+?[0-9]{7,15}$")]


class ProfileResponse(BaseModel):
    id: UUID
    full_name: str
    email: str | None
    phone: str | None
    role: str
    status: str
    avatar_path: str | None
    created_at: datetime
    updated_at: datetime


class ProfileUpdate(StrictModel):
    """Only these fields are editable. Email, role and status are deliberately absent (extra fields => 422)."""

    full_name: Annotated[str, StringConstraints(min_length=1, max_length=120)] | None = None
    phone: Phone | None = None
    avatar_path: Annotated[str, StringConstraints(min_length=3, max_length=300)] | None = None
