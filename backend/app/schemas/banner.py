import re
from datetime import datetime
from enum import Enum
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, StringConstraints, model_validator

from app.schemas.category import ImagePath
from app.schemas.common import StrictModel

_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


class ActionType(str, Enum):
    none = "none"
    product = "product"
    category = "category"
    service = "service"
    url = "url"


def _check_action(action_type: str | None, action_value: str | None) -> None:
    if action_type in (None,):
        return
    if action_type == ActionType.none.value:
        if action_value:
            raise ValueError("action_value must be empty when action_type is 'none'")
    elif action_type == ActionType.url.value:
        if not action_value or not re.match(r"^https://[^\s]{3,500}$", action_value):
            raise ValueError("action_value must be an https:// URL")
    else:
        if not action_value or not _UUID.match(action_value):
            raise ValueError(f"action_value must be the id (UUID) of the {action_type}")


class BannerCreate(StrictModel):
    title: Annotated[str, StringConstraints(min_length=1, max_length=120)]
    subtitle: Annotated[str, StringConstraints(max_length=300)] | None = None
    image_path: ImagePath  # object in the public `banners` bucket
    action_type: ActionType = ActionType.none
    action_value: str | None = None
    sort_order: int = 0
    is_active: bool = True
    starts_at: datetime | None = None
    ends_at: datetime | None = None

    @model_validator(mode="after")
    def _valid(self):
        _check_action(self.action_type.value, self.action_value)
        if self.starts_at and self.ends_at and self.ends_at <= self.starts_at:
            raise ValueError("ends_at must be after starts_at")
        return self


class BannerUpdate(StrictModel):
    title: Annotated[str, StringConstraints(min_length=1, max_length=120)] | None = None
    subtitle: Annotated[str, StringConstraints(max_length=300)] | None = None
    image_path: ImagePath | None = None
    action_type: ActionType | None = None
    action_value: str | None = None
    sort_order: int | None = None
    is_active: bool | None = None
    starts_at: datetime | None = None
    ends_at: datetime | None = None


class BannerOut(BaseModel):
    id: UUID
    title: str
    subtitle: str | None
    image_url: str
    action_type: ActionType
    action_value: str | None
    sort_order: int


class AdminBannerOut(BannerOut):
    image_path: str
    is_active: bool
    starts_at: datetime | None
    ends_at: datetime | None
    created_at: datetime
    updated_at: datetime
