"""Builds API views of orders from database rows. Everything comes from the order's own snapshot columns, never from the
current product/vendor rows, so history stays correct after listings change."""
from typing import Any

from app.core.money import ZERO, q2
from app.integrations.supabase import public_storage_url
from app.repositories.base import Row
from app.repositories.order_repository import OrderRepository

CUSTOMER_CANCELLABLE = ("pending", "accepted")
ACTIVE_VENDOR = ("pending", "accepted", "preparing", "ready_for_dispatch", "out_for_delivery")


def item_out(r: Row) -> dict[str, Any]:
    return {"id": r["id"], "product_id": r.get("product_id"), "product_name": r["product_name"], "product_brand": r.get("product_brand"),
            "product_model": r.get("product_model"), "product_condition": r.get("product_condition"),
            "image_url": public_storage_url("product-images", r["product_image_path"]) if r.get("product_image_path") else None,
            "unit_price": r["unit_price"], "quantity": r["quantity"], "line_total": r["line_total"]}


def vendor_order_out(vo: Row, items: list[Row]) -> dict[str, Any]:
    keys = ("id", "vendor_order_number", "vendor_id", "vendor_name", "status", "subtotal", "delivery_charge", "discount_amount", "total_amount",
            "accepted_at", "delivered_at", "rejection_reason", "cancellation_reason")
    return {**{k: vo.get(k) for k in keys}, "items": [item_out(i) for i in items if i["vendor_order_id"] == vo["id"]]}


def can_cancel(order: Row, vos: list[Row]) -> bool:
    """Customer may cancel while nothing has been prepared yet (same rule the database enforces)."""
    if order["status"] not in ("pending", "confirmed"):
        return False
    live = [v for v in vos if v["status"] in ACTIVE_VENDOR]
    return bool(live) and all(v["status"] in CUSTOMER_CANCELLABLE for v in live)


def summary(order: Row, vos: list[Row], items: list[Row]) -> dict[str, Any]:
    keys = ("id", "order_number", "status", "payment_method", "payment_status", "subtotal", "delivery_charge", "discount_amount", "total_amount",
            "created_at", "cancelled_reason")
    return {**{k: order.get(k) for k in keys}, "item_count": sum(i["quantity"] for i in items if i["order_id"] == order["id"]),
            "vendor_count": sum(1 for v in vos if v["order_id"] == order["id"])}


def detail(order: Row, vos: list[Row], items: list[Row]) -> dict[str, Any]:
    mine = [v for v in vos if v["order_id"] == order["id"]]
    return {**summary(order, vos, items), "delivery_address": order["delivery_address"], "coupon_code": order.get("coupon_code"),
            "customer_note": order.get("customer_note"), "payment_due_at": order.get("payment_due_at"), "cancelled_at": order.get("cancelled_at"),
            "can_cancel": can_cancel(order, mine), "vendor_orders": [vendor_order_out(v, items) for v in mine]}


def payment_out(p: Row) -> dict[str, Any]:
    open_amount = q2(p["amount"]) if p["status"] in ("pending", "processing") else ZERO
    keys = ("id", "order_id", "method", "provider", "provider_order_id", "status", "amount", "currency", "refunded_amount", "paid_at", "failure_reason", "created_at")
    return {**{k: p.get(k) for k in keys}, "amount_due": open_amount}


def load_detail(repo: OrderRepository, order: Row) -> dict[str, Any]:
    vos = repo.vendor_orders_for([order["id"]])
    return detail(order, vos, repo.items_for([order["id"]]))


def load_summaries(repo: OrderRepository, orders: list[Row]) -> list[dict[str, Any]]:
    ids = [o["id"] for o in orders]
    vos, items = repo.vendor_orders_for(ids), repo.items_for(ids)
    return [summary(o, vos, items) for o in orders]

