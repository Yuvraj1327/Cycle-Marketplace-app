from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class NotificationOut(BaseModel):
    id: UUID
    type: str
    title: str
    message: str
    related_type: str | None
    related_id: UUID | None
    is_read: bool
    read_at: datetime | None
    created_at: datetime


class NotificationPage(BaseModel):
    items: list[NotificationOut]
    total: int
    page: int
    limit: int
    pages: int
    unread_count: int


class ReadAllResult(BaseModel):
    marked_read: int
