from __future__ import annotations

from app.core.exceptions import NotFoundError, conflict
from app.core.search import slugify
from app.repositories.service_repository import ServiceCategoryRepository, VendorServiceRepository
from app.schemas.service import ServiceCategoryCreate, ServiceCategoryUpdate
from app.services import _service_views as sv
from app.services._updates import changes


class ServiceCategoryService:
    """Public reads use the anonymous client (RLS: active only); admin writes run as the admin (RLS is_admin)."""

    def __init__(self, db, *, admin: bool = False):
        self.repo = ServiceCategoryRepository(db)
        self.services = VendorServiceRepository(db)
        self.admin = admin

    def list(self) -> list[dict]:
        rows = self.repo.list_all(active_only=not self.admin)
        return [self._out(r) for r in rows]

    def get(self, category_id: str, *, with_services: bool = False) -> dict:
        row = self.repo.find(category_id)
        if row is None or (not self.admin and not row["is_active"]):
            raise NotFoundError("Service category not found.")
        out = self._out(row)
        if with_services:
            from app.services.service_catalog_service import ServiceCatalogService
            out["services"] = ServiceCatalogService(self.repo.client).list(category_id=category_id, vendor_id=None, q=None, page=1, limit=50)["items"]
        return out

    def create(self, body: ServiceCategoryCreate) -> dict:
        values = body.model_dump(mode="json", exclude={"slug"})
        values["slug"] = body.slug or self._unique_slug(body.name)
        return self._out(self.repo.create(values))

    def update(self, category_id: str, body: ServiceCategoryUpdate) -> dict:
        if self.repo.find(category_id) is None:
            raise NotFoundError("Service category not found.")
        row = self.repo.update(category_id, changes(body, nullable={"description", "image_path"}))
        return self._out(row)

    def delete(self, category_id: str) -> None:
        if self.repo.find(category_id) is None:
            raise NotFoundError("Service category not found.")
        n, b = self.repo.service_count(category_id, public_only=False), self.repo.booking_count(category_id)
        if n or b:
            raise conflict("category_in_use", f"{n} vendor service(s) and {b} booking(s) use this category. Deactivate it instead of deleting.")
        self.repo.delete(category_id)

    def _out(self, r: dict) -> dict:
        out = {"id": r["id"], "name": r["name"], "slug": r["slug"], "description": r.get("description"), "image_url": sv.category_image(r), "sort_order": r["sort_order"],
               "service_count": self.repo.service_count(r["id"], public_only=not self.admin)}
        if self.admin:
            out.update(is_active=r["is_active"], image_path=r.get("image_path"), booking_count=self.repo.booking_count(r["id"]), created_at=r["created_at"], updated_at=r["updated_at"])
        return out

    def _unique_slug(self, name: str) -> str:
        base = slugify(name) or "service-category"
        taken = self.repo.slugs_like(base)
        if base not in taken:
            return base
        n = 2
        while f"{base}-{n}" in taken:
            n += 1
        return f"{base}-{n}"


