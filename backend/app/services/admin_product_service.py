from __future__ import annotations

from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict, unprocessable
from app.core.search import sanitize_term
from app.repositories.commerce_config_repository import AuditRepository
from app.repositories.product_repository import ProductFilters, ProductRepository
from app.schemas.product import ApprovalUpdate
from app.services import _catalog


class AdminProductService:
    """Runs with the ADMIN'S OWN token: RLS `is_admin()` policies and the guard triggers (which stamp reviewed_by/at)
    do the authorisation; the route-level `require_admin` is the first barrier."""

    def __init__(self, db, admin_db=None):
        self.db = db
        self.products = ProductRepository(db)
        self.audit = AuditRepository(admin_db) if admin_db is not None else None

    def _audit(self, admin: CurrentUser | None, action: str, product_id: UUID, details: dict) -> None:
        if self.audit is not None and admin is not None:
            self.audit.record(admin.id, action, "product", str(product_id), details)

    def list(self, *, q, vendor_id, category_id, condition, approval_status, moderation_status, is_active, is_featured, page, limit,
             in_stock=None, sort="newest") -> dict:
        f = ProductFilters(q=sanitize_term(q) or None if q else None, vendor_id=str(vendor_id) if vendor_id else None,
                           category_ids=[str(category_id)] if category_id else None, condition=condition,
                           approval_status=approval_status, is_active=is_active, is_featured=is_featured, in_stock=in_stock)
        if moderation_status == "inactive":
            f.is_active = False
        elif moderation_status:
            f.approval_status, f.is_active = moderation_status, True
        rows, total = self.products.search(f, sort=sort, page=page, limit=limit)
        ctx = self._ctx(rows)
        return _catalog.page([_catalog.admin_view(r, ctx) for r in rows], total, page, limit)

    def get(self, product_id: UUID) -> dict:
        return self._view(self._find(product_id))

    def set_approval(self, product_id: UUID, data: ApprovalUpdate, admin: CurrentUser | None = None) -> dict:
        before = self._find(product_id)
        if data.approval_status.value == "rejected" and not (data.review_notes or "").strip():
            raise unprocessable("review_notes_required", "Give the vendor a reason when rejecting a listing.")
        row = self.products.modify(str(product_id), {"approval_status": data.approval_status.value, "review_notes": data.review_notes})
        self._audit(admin, "product_approval_changed", product_id, {"from": before["approval_status"], "to": data.approval_status.value, "review_notes": data.review_notes})
        return self._view(row)

    def set_active(self, product_id: UUID, is_active: bool, admin: CurrentUser | None = None) -> dict:
        self._find(product_id)
        update = {"is_active": is_active} if is_active else {"is_active": False, "is_featured": False}  # inactive can't be featured
        row = self.products.modify(str(product_id), update)
        self._audit(admin, "product_activated" if is_active else "product_deactivated", product_id, {"is_active": is_active})
        return self._view(row)

    def set_featured(self, product_id: UUID, is_featured: bool, admin: CurrentUser | None = None) -> dict:
        row = self._find(product_id)
        if is_featured and (row["approval_status"] != "approved" or not row["is_active"]):
            raise conflict("not_publicly_visible", "Only approved, active listings can be featured.")
        row = self.products.modify(str(product_id), {"is_featured": is_featured})
        self._audit(admin, "product_featured" if is_featured else "product_unfeatured", product_id, {"is_featured": is_featured})
        return self._view(row)

    def _find(self, product_id: UUID) -> dict:
        row = self.products.find(str(product_id))
        if row is None:
            raise NotFoundError("Product not found.")
        return row

    def _ctx(self, rows):
        return _catalog.load_context(self.db, rows, vendor_table="vendor_profiles", vendor_cols=_catalog.ADMIN_VENDOR_COLS, with_categories=True)

    def _view(self, row):
        return _catalog.admin_view(row, self._ctx([row]))
