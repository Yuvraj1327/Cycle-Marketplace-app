from datetime import datetime
from enum import Enum
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, StringConstraints, model_validator

from app.schemas.common import StrictModel


class TicketType(str, Enum):
    complaint = "complaint"
    support_request = "support_request"
    dispute = "dispute"


class TicketStatus(str, Enum):
    open = "open"
    in_progress = "in_progress"
    resolved = "resolved"
    closed = "closed"


class TicketCreate(StrictModel):
    type: TicketType = TicketType.support_request
    subject: Annotated[str, StringConstraints(min_length=3, max_length=150)]
    description: Annotated[str, StringConstraints(min_length=10, max_length=3000)]
    order_id: UUID | None = None
    service_booking_id: UUID | None = None

    @model_validator(mode="after")
    def _one(self):
        if self.order_id and self.service_booking_id:
            raise ValueError("link a ticket to an order OR a service booking, not both")
        return self


class TicketOut(BaseModel):
    id: UUID
    ticket_number: str
    type: TicketType
    subject: str
    description: str
    status: TicketStatus
    order_id: UUID | None
    service_booking_id: UUID | None
    resolution: str | None
    resolved_at: datetime | None
    created_at: datetime
    updated_at: datetime


class AdminTicketOut(TicketOut):
    requester_id: UUID
    assigned_to: UUID | None
    admin_notes: str | None


class TicketUpdate(StrictModel):
    status: TicketStatus | None = None
    assigned_to: UUID | None = None
    admin_notes: Annotated[str, StringConstraints(max_length=2000)] | None = None
    resolution: Annotated[str, StringConstraints(max_length=2000)] | None = None
