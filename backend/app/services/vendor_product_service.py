"""Vendor-side product + inventory management. Every operation is scoped to the calling vendor's id taken from the
authenticated session (never from the request body) and runs as the user, so RLS applies as a second barrier."""

from __future__ import annotations

import logging
from uuid import UUID

from app.core.dependencies import ApprovedVendor
from app.core.exceptions import NotFoundError, unprocessable
from app.repositories.category_repository import CategoryRepository
from app.repositories.product_image_repository import ProductImageRepository
from app.repositories.product_repository import ProductFilters, ProductRepository
from app.repositories.settings_repository import SettingsRepository
from app.schemas.product import ProductCreate, ProductPatch, ProductReplace
from app.services import _catalog
from app.services._updates import changes

logger = logging.getLogger(__name__)

APPROVAL_SETTING = "marketplace.require_listing_approval"
NULLABLE = {"description", "brand", "model"}


def check_condition(product_type: str, condition: str) -> None:
    if (product_type == "new_cycle" and condition != "new") or (product_type == "used_cycle" and condition != "used"):
        raise unprocessable("invalid_condition", f"A '{product_type}' listing must have condition "
                            f"'{'new' if product_type == 'new_cycle' else 'used'}'.")


class VendorProductService:
    def __init__(self, db, admin_db, access_token: str = ""):
        self.db = db
        self.products = ProductRepository(db)
        self.categories = CategoryRepository(db)
        self.images = ProductImageRepository(db)
        # service-role access is limited to (a) reading platform settings, (b) moving a listing into 'approved'/'pending'
        # according to platform policy. Neither value is ever taken from the request.
        self._admin_products = ProductRepository(admin_db)
        self._settings = SettingsRepository(admin_db)
        self.access_token = access_token

    # ---------------- policy ----------------
    def _require_approval(self) -> bool:
        value = self._settings.get_value(APPROVAL_SETTING, True)
        return value if isinstance(value, bool) else True   # unset / malformed => safest default: moderation ON

    def _route_through_moderation(self, product_id: str) -> dict:
        """Applies the platform's moderation policy to a new (or resubmitted) listing."""
        if self._require_approval():
            return self._admin_products.modify(product_id, {"approval_status": "pending", "review_notes": None}) or {}
        return self._admin_products.modify(product_id, {"approval_status": "approved", "review_notes": "Auto-approved (listing approval disabled)"}) or {}

    # ---------------- reads ----------------
    def list(self, vendor: ApprovedVendor, *, q, approval_status, is_active, category_id, page, limit, product_type=None, in_stock=None) -> dict:
        from app.core.search import sanitize_term
        f = ProductFilters(q=sanitize_term(q) or None if q else None, vendor_id=vendor.vendor["id"], approval_status=approval_status,
                           is_active=is_active, category_ids=[str(category_id)] if category_id else None, product_type=product_type, in_stock=in_stock)
        rows, total = self.products.search(f, sort="newest", page=page, limit=limit)
        ctx = _catalog.load_context(self.db, rows)
        return _catalog.page([_catalog.owner_view(r, ctx) for r in rows], total, page, limit)

    def get(self, vendor: ApprovedVendor, product_id: UUID) -> dict:
        return self._view(self._owned(vendor, product_id))

    # ---------------- writes ----------------
    def create(self, vendor: ApprovedVendor, data: ProductCreate) -> dict:
        category = self._category(data.category_id)
        check_condition(category["kind"], data.condition.value)
        values = data.model_dump(mode="json", exclude={"category_id"})
        row = self.products.insert({**values, "category_id": category["id"], "product_type": category["kind"], "vendor_id": vendor.vendor["id"]})
        row = {**row, **self._route_through_moderation(row["id"])}
        return self._view(row)

    def replace(self, vendor: ApprovedVendor, product_id: UUID, data: ProductReplace) -> dict:
        values = data.model_dump(mode="json")
        return self._apply(vendor, product_id, values)

    def patch(self, vendor: ApprovedVendor, product_id: UUID, data: ProductPatch) -> dict:
        return self._apply(vendor, product_id, changes(data, nullable=NULLABLE))

    def delete(self, vendor: ApprovedVendor, product_id: UUID) -> dict:
        """Hard-delete only listings that were never ordered; otherwise deactivate so order history stays intact."""
        row = self._owned(vendor, product_id)
        if self.products.has_orders(row["id"]):
            self.products.modify(row["id"], {"is_active": False, "is_available": False}, vendor_id=vendor.vendor["id"])
            return {"result": "deactivated", "detail": "This product has been ordered before, so it was deactivated instead of deleted."}
        paths = [i["storage_path"] for i in self.images.for_product(row["id"])]
        self.products.remove(row["id"], vendor_id=vendor.vendor["id"])
        from app.integrations.supabase import delete_storage_object
        for path in paths:  # best effort: DB row is gone, so a failed file delete must not fail the request
            try:
                delete_storage_object(self.access_token, "product-images", path)
            except Exception:  # noqa: BLE001
                logger.warning("could not delete storage object %s", path)
        return {"result": "deleted", "detail": "Product deleted."}

    # ---------------- internals ----------------
    def _apply(self, vendor: ApprovedVendor, product_id: UUID, values: dict) -> dict:
        current = self._owned(vendor, product_id)
        if "category_id" in values:
            category = self._category(UUID(str(values["category_id"])))
            values["category_id"], values["product_type"] = category["id"], category["kind"]
        product_type = values.get("product_type", current["product_type"])
        check_condition(product_type, values.get("condition", current["condition"]))
        row = self.products.modify(current["id"], values, vendor_id=vendor.vendor["id"])
        if row is None:
            raise NotFoundError("Product not found.")
        if current["approval_status"] == "rejected":  # editing a rejected listing = resubmission for review
            row = {**row, **self._route_through_moderation(row["id"])}
        return self._view(row)

    def _owned(self, vendor: ApprovedVendor, product_id: UUID) -> dict:
        row = self.products.find(str(product_id), vendor_id=vendor.vendor["id"])
        if row is None:  # also the answer for another vendor's product: its existence is not revealed
            raise NotFoundError("Product not found.")
        return row

    def _category(self, category_id: UUID) -> dict:
        cat = self.categories.find(str(category_id))
        if cat is None or not cat["is_active"]:
            raise unprocessable("invalid_category", "Choose an existing, active category.")
        return cat

    def _view(self, row: dict) -> dict:
        return _catalog.owner_view(row, _catalog.load_context(self.db, [row], with_categories=True))
