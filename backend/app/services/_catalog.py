"""Shared response builders: batch-loads images / sellers / categories for a page of products (no N+1)."""
from dataclasses import dataclass, field
from typing import Any

from app.integrations.supabase import public_storage_url
from app.repositories.base import Row
from app.repositories.category_repository import CategoryRepository
from app.repositories.product_image_repository import ProductImageRepository

PUBLIC_VENDOR_COLS = "id,business_name,city,state,business_types,pickup_available"
ADMIN_VENDOR_COLS = "id,business_name,verification_status,city,state,contact_phone,contact_email,business_types,pickup_available"


def image_url(path: str) -> str:
    return public_storage_url("product-images", path)


def moderation_status(row: Row) -> str:
    return "inactive" if not row["is_active"] else row["approval_status"]


def image_out(row: Row) -> dict[str, Any]:
    return {"id": row["id"], "url": image_url(row["storage_path"]), "storage_path": row["storage_path"],
            "alt_text": row.get("alt_text"), "sort_order": row["sort_order"], "is_primary": row["is_primary"]}


@dataclass
class Context:
    images: dict[str, list[Row]] = field(default_factory=dict)
    vendors: dict[str, Row] = field(default_factory=dict)
    categories: dict[str, Row] = field(default_factory=dict)


def load_context(client, products: list[Row], *, vendor_table: str = "vendor_public_profiles",
                 vendor_cols: str = PUBLIC_VENDOR_COLS, with_categories: bool = False) -> Context:
    ctx = Context()
    if not products:
        return ctx
    ids = [p["id"] for p in products]
    for img in ProductImageRepository(client).for_products(ids):
        ctx.images.setdefault(img["product_id"], []).append(img)
    vendor_ids = sorted({p["vendor_id"] for p in products})
    rows = ProductImageRepository(client)._run(client.table(vendor_table).select(vendor_cols).in_("id", vendor_ids)).data
    ctx.vendors = {r["id"]: r for r in rows}
    if with_categories:
        ctx.categories = {c["id"]: c for c in CategoryRepository(client).by_ids(sorted({p["category_id"] for p in products}))}
    return ctx


def seller(row: Row | None) -> dict[str, Any] | None:
    if not row:
        return None
    return {"id": row["id"], "business_name": row["business_name"], "city": row.get("city"), "state": row.get("state"),
            "business_types": row.get("business_types") or [], "pickup_available": bool(row.get("pickup_available"))}


def _primary_url(imgs: list[Row]) -> str | None:
    if not imgs:
        return None
    primary = next((i for i in imgs if i["is_primary"]), imgs[0])
    return image_url(primary["storage_path"])


def summary(row: Row, ctx: Context) -> dict[str, Any]:
    in_stock = bool(row["is_available"]) and row["stock_quantity"] > 0
    return {
        "id": row["id"], "name": row["name"], "brand": row.get("brand"), "model": row.get("model"),
        "product_type": row["product_type"], "category_id": row["category_id"], "condition": row["condition"],
        "price": row["price"], "is_available": row["is_available"], "in_stock": in_stock,
        "stock_quantity": row["stock_quantity"], "is_featured": row["is_featured"],
        "primary_image_url": _primary_url(ctx.images.get(row["id"], [])),
        "vendor": seller(ctx.vendors.get(row["vendor_id"])), "created_at": row["created_at"],
    }


def detail(row: Row, ctx: Context) -> dict[str, Any]:
    cat = ctx.categories.get(row["category_id"])
    return {
        **summary(row, ctx),
        "description": row.get("description"), "specifications": row.get("specifications") or {},
        "category": {"id": cat["id"], "name": cat["name"], "slug": cat["slug"], "kind": cat["kind"]} if cat else None,
        "images": [image_out(i) for i in ctx.images.get(row["id"], [])], "updated_at": row["updated_at"],
    }


def owner_view(row: Row, ctx: Context) -> dict[str, Any]:
    return {**detail(row, ctx), "is_active": row["is_active"], "approval_status": row["approval_status"],
            "moderation_status": moderation_status(row), "review_notes": row.get("review_notes"),
            "reviewed_at": row.get("reviewed_at")}


def admin_view(row: Row, ctx: Context) -> dict[str, Any]:
    v = ctx.vendors.get(row["vendor_id"])
    return {**owner_view(row, ctx), "reviewed_by": row.get("reviewed_by"),
            "vendor_admin": {k: v.get(k) for k in ("id", "business_name", "verification_status", "city", "state", "contact_phone", "contact_email")} if v else None}


def page(items: list[Any], total: int, page_no: int, limit: int) -> dict[str, Any]:
    return {"items": items, "total": total, "page": page_no, "limit": limit, "pages": -(-total // limit) if total else 0}
