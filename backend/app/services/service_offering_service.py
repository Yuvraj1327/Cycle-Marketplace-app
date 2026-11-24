"""Vendor-managed services (price, duration, availability, capacity). Vendor id always comes from the approved-vendor session."""
from __future__ import annotations

from uuid import UUID

from app.core.dependencies import ApprovedVendor
from app.core.exceptions import NotFoundError, unprocessable
from app.repositories.service_repository import ServiceCategoryRepository, VendorServiceRepository
from app.schemas.service import ServiceCreate, ServicePatch, ServiceReplace
from app.services import _catalog
from app.services import _service_views as sv
from app.services._updates import changes

NULLABLE = {"description", "estimated_duration_minutes", "available_days"}


class ServiceOfferingService:
    def __init__(self, db):
        self.repo = VendorServiceRepository(db)
        self.categories = ServiceCategoryRepository(db)

    def list(self, vendor: ApprovedVendor, *, is_active, category_id, q, page: int, limit: int) -> dict:
        rows, total = self.repo.search(vendor_id=vendor.vendor["id"], is_active=is_active, category_id=str(category_id) if category_id else None, q_name=q, page=page, limit=limit)
        cats = {c["id"]: c for c in self.repo.categories_by_ids(sorted({r["service_category_id"] for r in rows}))}
        return _catalog.page([sv.service_owner(r, cats) for r in rows], total, page, limit)

    def get(self, vendor: ApprovedVendor, service_id: UUID) -> dict:
        return self._view(self._own(vendor, service_id))

    def create(self, vendor: ApprovedVendor, body: ServiceCreate) -> dict:
        self._check_category(body.service_category_id)
        values = {**body.model_dump(mode="json"), "vendor_id": vendor.vendor["id"]}
        return self._view(self.repo.create(values))        # unique (vendor, category, name) -> 409 via the database

    def replace(self, vendor: ApprovedVendor, service_id: UUID, body: ServiceReplace) -> dict:
        self._own(vendor, service_id)
        self._check_category(body.service_category_id)
        return self._write(vendor, service_id, body.model_dump(mode="json"))

    def patch(self, vendor: ApprovedVendor, service_id: UUID, body: ServicePatch) -> dict:
        self._own(vendor, service_id)
        values = changes(body, nullable=NULLABLE)
        if "service_category_id" in values:
            self._check_category(UUID(values["service_category_id"]))
        return self._write(vendor, service_id, values)

    def delete(self, vendor: ApprovedVendor, service_id: UUID) -> dict:
        """Hard-delete only a service that never received a booking; otherwise deactivate so booking history stays linked."""
        s = self._own(vendor, service_id)
        if self.repo.has_bookings(s["id"]):
            self.repo.modify(s["id"], {"is_active": False, "is_available": False}, vendor_id=vendor.vendor["id"])
            return {"result": "deactivated", "detail": "This service has bookings, so it was deactivated instead of deleted. Booking history is unchanged."}
        self.repo.remove(s["id"], vendor_id=vendor.vendor["id"])
        return {"result": "deleted", "detail": "Service deleted."}

    # ---------------- internals
    def _write(self, vendor: ApprovedVendor, service_id: UUID, values: dict) -> dict:
        row = self.repo.modify(str(service_id), values, vendor_id=vendor.vendor["id"])
        if row is None:
            raise NotFoundError("Service not found.")
        return self._view(row)

    def _own(self, vendor: ApprovedVendor, service_id: UUID) -> dict:
        row = self.repo.find(str(service_id), vendor_id=vendor.vendor["id"])
        if row is None:
            raise NotFoundError("Service not found.")          # also the answer for another vendor's service
        return row

    def _check_category(self, category_id: UUID) -> None:
        cat = self.categories.find(str(category_id))
        if cat is None or not cat["is_active"]:
            raise unprocessable("invalid_category", "Choose an existing, active service category (only administrators create categories).")

    def _view(self, row: dict) -> dict:
        return sv.service_owner(row, {c["id"]: c for c in self.repo.categories_by_ids([row["service_category_id"]])})
