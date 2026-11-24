from uuid import UUID

from pydantic import BaseModel, Field

from app.schemas.common import Money, StrictModel
from app.schemas.product import SellerOut


class CartItemAdd(StrictModel):
    product_id: UUID
    quantity: int = Field(1, ge=1, le=100)


class CartItemUpdate(StrictModel):
    quantity: int = Field(ge=1, le=100)


class CartProduct(BaseModel):
    id: UUID
    name: str
    brand: str | None
    model: str | None
    condition: str
    price: Money
    stock_quantity: int
    primary_image_url: str | None
    vendor: SellerOut | None


class CartItemOut(BaseModel):
    id: UUID
    product_id: UUID
    quantity: int
    product: CartProduct | None          # null when the product is no longer publicly listed
    unit_price: Money | None             # CURRENT price
    line_total: Money | None
    status: str                          # ok | not_listed | unavailable | out_of_stock | insufficient_stock
    available_quantity: int
    price_changed: bool
    previous_price: Money | None


class CartVendorGroup(BaseModel):
    vendor_id: UUID | None
    business_name: str | None
    item_count: int
    subtotal: Money


class CartSummary(BaseModel):
    distinct_items: int
    total_quantity: int
    subtotal: Money                      # only items with status "ok"; excludes delivery/service charges and discounts
    multi_vendor: bool
    has_unavailable_items: bool
    has_price_changes: bool


class CartOut(BaseModel):
    id: UUID
    items: list[CartItemOut]
    vendors: list[CartVendorGroup]
    summary: CartSummary


class WishlistAdd(StrictModel):
    product_id: UUID


class WishlistItemOut(BaseModel):
    id: UUID
    product_id: UUID
    added_at: str
    product: CartProduct | None
    status: str                          # ok | not_listed | unavailable | out_of_stock


class WishlistOut(BaseModel):
    id: UUID
    items: list[WishlistItemOut]
    total: int
