from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from app.schemas.profile import ProfileResponse


class SessionInfo(BaseModel):
    session_id: str | None
    assurance_level: str | None
    token_expires_at: datetime


class MeResponse(BaseModel):
    id: UUID
    email: str | None
    phone: str | None
    role: str
    status: str
    vendor_verification_status: str | None = None
    session: SessionInfo
    profile: ProfileResponse
