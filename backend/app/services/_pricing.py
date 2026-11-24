"""Pure, decimal-safe pricing: discount, delivery charge, commission, allocation. No I/O - easy to test exhaustively."""
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from app.core.money import ZERO, allocate, q2
from app.services.checkout_settings import DeliveryRule

Row = dict[str, Any]


def _parse_ts(value: Any) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def coupon_problem(coupon: Row, subtotal: Decimal, uses_by_customer: int, now: datetime | None = None) -> str | None:
    """Reason code if the coupon cannot be used for this cart, else None."""
    now = now or datetime.now(timezone.utc)
    if not coupon["is_active"]:
        return "inactive"
    start, end = _parse_ts(coupon.get("valid_from")), _parse_ts(coupon.get("valid_until"))
    if start and start > now:
        return "not_started"
    if end and end <= now:
        return "expired"
    if coupon["applies_to"] == "services":
        return "not_for_products"
    if subtotal < q2(coupon["min_order_amount"]):
        return "below_minimum_order"
    if coupon.get("usage_limit") is not None and coupon["used_count"] >= coupon["usage_limit"]:
        return "usage_limit_reached"
    if coupon.get("per_user_limit") is not None and uses_by_customer >= coupon["per_user_limit"]:
        return "already_used"
    return None


def discount_amount(coupon: Row, subtotal: Decimal) -> Decimal:
    value = Decimal(str(coupon["discount_value"]))
    amount = q2(subtotal * value / 100) if coupon["discount_type"] == "percentage" else q2(value)
    if coupon.get("max_discount_amount") is not None:
        amount = min(amount, q2(coupon["max_discount_amount"]))
    return min(amount, subtotal)           # a discount can never exceed the goods value


def delivery_charges(rule: DeliveryRule | None, vendor_subtotals: list[Decimal]) -> list[Decimal]:
    """Delivery charge per vendor order (same order as `vendor_subtotals`)."""
    if rule is None:
        return [ZERO for _ in vendor_subtotals]
    order_subtotal = sum(vendor_subtotals, Decimal(0))
    if rule.free_above is not None and order_subtotal >= rule.free_above:
        return [ZERO for _ in vendor_subtotals]
    if rule.per == "vendor_order":
        return [rule.amount for _ in vendor_subtotals]
    return allocate(rule.amount, vendor_subtotals)


def select_commission_rule(rules: list[Row], vendor_id: str, category_id: str, now: datetime | None = None) -> Row | None:
    """Most specific active rule wins: vendor-specific, then category-specific, then global; then priority; then newest."""
    now = now or datetime.now(timezone.utc)
    candidates = []
    for r in rules:
        if not r["is_active"]:
            continue
        start, end = _parse_ts(r.get("effective_from")), _parse_ts(r.get("effective_until"))
        if (start and start > now) or (end and end <= now):
            continue
        if r.get("vendor_id") not in (None, vendor_id) or r.get("category_id") not in (None, category_id):
            continue
        candidates.append(r)
    if not candidates:
        return None
    return max(candidates, key=lambda r: (r.get("vendor_id") is not None, r.get("category_id") is not None, r.get("priority", 0), str(r.get("created_at", "")), r["id"]))


def commission_for_line(rule: Row, unit_price: Decimal, quantity: int) -> Decimal:
    """percentage: % of the line value. fixed: flat amount PER UNIT sold. Never more than the line value."""
    line = q2(unit_price * quantity)
    value = Decimal(str(rule["commission_value"]))
    amount = q2(line * value / 100) if rule["commission_type"] == "percentage" else q2(value * quantity)
    return min(amount, line)
