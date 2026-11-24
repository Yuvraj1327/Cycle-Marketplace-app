import json
from datetime import datetime
from decimal import Decimal
from enum import Enum
from typing import Annotated, Any
from uuid import UUID

from pydantic import BaseModel, Field, PlainSerializer, StringConstraints, field_validator

from app.schemas.category import CategoryKind
from app.schemas.common import Money, StrictModel

MoneyIn = Annotated[
    Decimal,
    Field(ge=0, le=10_000_000, max_digits=12, decimal_places=2),
    PlainSerializer(lambda d: float(d), return_type=float, when_used="json"),
]
Stock = Annotated[int, Field(ge=0, le=1_000_000)]
Name = Annotated[str, StringConstraints(min_length=2, max_length=200)]
Short = Annotated[str, StringConstraints(max_length=100)]
LongText = Annotated[str, StringConstraints(max_length=5000)]


class Condition(str, Enum):
    new = "new"
    used = "used"


class ApprovalStatus(str, Enum):
    pending = "pending"
    approved = "approved"
    rejected = "rejected"


class SortBy(str, Enum):
    relevance = "relevance"
    price_low_to_high = "price_low_to_high"
    price_high_to_low = "price_high_to_low"
    newest = "newest"


def _check_specs(v: dict[str, Any] | None) -> dict[str, Any] | None:
    """Free-form but bounded: flat-ish key/value facts (frame_size, gears, material, ...)."""
    if v is None:
        return v
    if len(v) > 40:
        raise ValueError("at most 40 specification entries")
    for k, val in v.items():
        if not (1 <= len(k) <= 60):
            raise ValueError("specification names must be 1-60 characters")
        items = val if isinstance(val, list) else [val]
        if len(items) > 20 or any(not isinstance(i, (str, int, float, bool)) or (isinstance(i, str) and len(i) > 300) for i in items):
            raise ValueError(f"specification '{k}' must be a short text/number/boolean (or a short list of them)")
    if len(json.dumps(v)) > 8000:
        raise ValueError("specifications are too large")
    return v


class ProductCreate(StrictModel):
    """Vendor identity, product_type and approval fields are NOT accepted: they come from the session / category."""

    category_id: UUID
    name: Name
    description: LongText | None = None
    brand: Short | None = None
    model: Short | None = None
    specifications: dict[str, Any] = Field(default_factory=dict)
    condition: Condition
    price: MoneyIn
    stock_quantity: Stock = 0
    is_available: bool = True

    _specs = field_validator("specifications")(_check_specs)


class ProductReplace(ProductCreate):
    """PUT: replaces every editable field (omitted optional fields are cleared / reset to defaults)."""

    is_active: bool = True


class ProductPatch(StrictModel):
    category_id: UUID | None = None
    name: Name | None = None
    description: LongText | None = None
    brand: Short | None = None
    model: Short | None = None
    specifications: dict[str, Any] | None = None
    condition: Condition | None = None
    price: MoneyIn | None = None
    stock_quantity: Stock | None = None
    is_available: bool | None = None
    is_active: bool | None = None

    _specs = field_validator("specifications")(_check_specs)


# ---- admin request bodies
class ApprovalUpdate(StrictModel):
    approval_status: ApprovalStatus
    review_notes: Annotated[str, StringConstraints(max_length=1000)] | None = None


class ActiveUpdate(StrictModel):
    is_active: bool


class FeaturedUpdate(StrictModel):
    is_featured: bool


# ---- responses
class ImageOut(BaseModel):
    id: UUID
    url: str
    storage_path: str
    alt_text: str | None
    sort_order: int
    is_primary: bool


class SellerOut(BaseModel):
    """Public seller summary only: no address line, phone or email."""

    id: UUID
    business_name: str
    city: str | None = None
    state: str | None = None
    business_types: list[str] = []
    pickup_available: bool = False


class CategoryRef(BaseModel):
    id: UUID
    name: str
    slug: str
    kind: CategoryKind


class ProductSummary(BaseModel):
    id: UUID
    name: str
    brand: str | None
    model: str | None
    product_type: CategoryKind
    category_id: UUID
    condition: Condition
    price: Money
    is_available: bool
    in_stock: bool
    stock_quantity: int
    is_featured: bool
    primary_image_url: str | None
    vendor: SellerOut | None
    created_at: datetime


class ProductDetail(ProductSummary):
    description: str | None
    specifications: dict[str, Any]
    category: CategoryRef | None
    images: list[ImageOut]
    updated_at: datetime


class VendorProductOut(ProductDetail):
    """Owner view: includes moderation state and the reviewer's note."""

    is_active: bool
    approval_status: ApprovalStatus
    moderation_status: str  # pending | approved | rejected | inactive
    review_notes: str | None
    reviewed_at: datetime | None


class AdminVendorOut(BaseModel):
    id: UUID
    business_name: str
    verification_status: str | None = None
    city: str | None = None
    state: str | None = None
    contact_phone: str | None = None
    contact_email: str | None = None


class AdminProductOut(VendorProductOut):
    vendor_admin: AdminVendorOut | None = None
    reviewed_by: UUID | None = None


class DeleteResult(BaseModel):
    result: str  # deleted | deactivated
    detail: str


# ---- images
class ImageRegister(StrictModel):
    storage_path: Annotated[str, StringConstraints(min_length=10, max_length=300)]
    alt_text: Annotated[str, StringConstraints(max_length=200)] | None = None
    is_primary: bool = False


class ImagePatch(StrictModel):
    alt_text: Annotated[str, StringConstraints(max_length=200)] | None = None
    is_primary: bool | None = None


class ImageOrder(StrictModel):
    image_ids: Annotated[list[UUID], Field(min_length=1, max_length=20)]
