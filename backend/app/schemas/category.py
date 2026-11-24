from datetime import datetime
from enum import Enum
from typing import Annotated
from uuid import UUID

from pydantic import AfterValidator, BaseModel, StringConstraints

from app.schemas.common import StrictModel


class CategoryKind(str, Enum):
    new_cycle = "new_cycle"
    used_cycle = "used_cycle"
    spare_part = "spare_part"
    accessory = "accessory"


Slug = Annotated[str, StringConstraints(pattern=r"^[a-z0-9]+(-[a-z0-9]+)*$", min_length=2, max_length=80)]
def _check_image_path(v: str) -> str:
    """A storage object path: relative, no traversal, allowed image extension only."""
    import re

    if ".." in v or v.startswith("/") or not re.fullmatch(r"[A-Za-z0-9_\-./ ]+\.(jpg|jpeg|png|webp)", v, flags=re.IGNORECASE):
        raise ValueError("must be a relative storage path ending in .jpg, .jpeg, .png or .webp")
    return v


ImagePath = Annotated[str, StringConstraints(min_length=3, max_length=300), AfterValidator(_check_image_path)]


class CategoryOut(BaseModel):
    id: UUID
    parent_id: UUID | None
    kind: CategoryKind
    name: str
    slug: str
    description: str | None
    image_url: str | None
    sort_order: int
    product_count: int | None = None


class AdminCategoryOut(CategoryOut):
    is_active: bool
    image_path: str | None
    created_at: datetime
    updated_at: datetime


class CategoryCreate(StrictModel):
    name: Annotated[str, StringConstraints(min_length=2, max_length=100)]
    kind: CategoryKind
    slug: Slug | None = None
    parent_id: UUID | None = None
    description: Annotated[str, StringConstraints(max_length=1000)] | None = None
    image_path: ImagePath | None = None  # object in the public `banners` bucket (admin-writable), e.g. categories/tyres.jpg
    sort_order: int = 0
    is_active: bool = True


class CategoryUpdate(StrictModel):
    name: Annotated[str, StringConstraints(min_length=2, max_length=100)] | None = None
    kind: CategoryKind | None = None
    slug: Slug | None = None
    parent_id: UUID | None = None
    description: Annotated[str, StringConstraints(max_length=1000)] | None = None
    image_path: ImagePath | None = None
    sort_order: int | None = None
    is_active: bool | None = None
