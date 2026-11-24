"""Shared by cart and wishlist: product brief + availability status."""
from decimal import Decimal
from typing import Any

from app.repositories.base import Row
from app.services import _catalog


def money(value: Any) -> Decimal:
    return Decimal(str(value)).quantize(Decimal("0.01"))


def availability(product: Row | None, quantity: int = 1) -> tuple[str, int]:
    """(status, available_quantity). A product the customer cannot see (RLS) is 'not_listed'."""
    if product is None or not product["is_active"] or product["approval_status"] != "approved":
        return "not_listed", 0
    stock = product["stock_quantity"]
    if not product["is_available"]:
        return "unavailable", 0
    if stock <= 0:
        return "out_of_stock", 0
    if quantity > stock:
        return "insufficient_stock", stock
    return "ok", stock


def brief(product: Row | None, ctx: _catalog.Context) -> dict[str, Any] | None:
    if product is None:
        return None
    s = _catalog.summary(product, ctx)
    return {k: s[k] for k in ("id", "name", "brand", "model", "condition", "price", "stock_quantity", "primary_image_url", "vendor")}
