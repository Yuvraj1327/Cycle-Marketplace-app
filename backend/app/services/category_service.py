from __future__ import annotations

from app.core.exceptions import NotFoundError, conflict, unprocessable
from app.core.search import slugify
from app.integrations.supabase import public_storage_url
from app.repositories.base import Row
from app.repositories.category_repository import CategoryRepository
from app.schemas.category import CategoryCreate, CategoryUpdate
from app.services._updates import changes


def category_out(row: Row, count: int | None = None, admin: bool = False) -> dict:
    out = {
        "id": row["id"], "parent_id": row.get("parent_id"), "kind": row["kind"], "name": row["name"], "slug": row["slug"],
        "description": row.get("description"), "sort_order": row["sort_order"], "product_count": count,
        "image_url": public_storage_url("banners", row["image_path"]) if row.get("image_path") else None,
    }
    if admin:
        out.update(is_active=row["is_active"], image_path=row.get("image_path"), created_at=row["created_at"], updated_at=row["updated_at"])
    return out


def descendants(rows: list[Row], root_id: str) -> list[str]:
    ids, frontier = [root_id], [root_id]
    while frontier:
        nxt = [r["id"] for r in rows if r.get("parent_id") in frontier and r["id"] not in ids]
        ids += nxt
        frontier = nxt
    return ids


class CategoryService:
    def __init__(self, repo: CategoryRepository, *, admin: bool = False):
        self.repo, self.admin = repo, admin

    # ---------------- reads (public = anon client; admin = admin user's client) ----------------
    def list(self, *, kind: str | None = None, parent_id: str | None = None, root_only: bool = False, include_counts: bool = True) -> list[dict]:
        rows = self.repo.list_all(kind=kind, parent_id=parent_id, root_only=root_only, active_only=not self.admin)
        return [category_out(r, self._count(r["id"]) if include_counts else None, self.admin) for r in rows]

    def get(self, category_id: str) -> dict:
        row = self.repo.find(category_id)
        if row is None or (not self.admin and not row["is_active"]):
            raise NotFoundError("Category not found.")
        return category_out(row, self._count(category_id), self.admin)

    def _count(self, category_id: str) -> int:
        return self.repo.product_count([category_id], public_only=not self.admin)

    # ---------------- admin writes ----------------
    def create(self, data: CategoryCreate) -> dict:
        values = data.model_dump(mode="json", exclude={"slug"})
        if data.parent_id:
            self._check_parent(str(data.parent_id), data.kind.value, own_id=None)
        values["slug"] = data.slug or self._unique_slug(data.name)
        return category_out(self.repo.create(values), 0, True)

    def update(self, category_id: str, data: CategoryUpdate) -> dict:
        current = self.repo.find(category_id)
        if current is None:
            raise NotFoundError("Category not found.")
        values = changes(data, nullable={"description", "image_path", "parent_id"})
        kind = values.get("kind", current["kind"])
        if "kind" in values and values["kind"] != current["kind"]:
            if self.repo.product_count([category_id], public_only=False) or self.repo.children(category_id):
                raise conflict("category_in_use", "The kind of a category with products or sub-categories cannot change.")
        if values.get("parent_id"):
            self._check_parent(values["parent_id"], kind, own_id=category_id)
        row = self.repo.update(category_id, values)
        return category_out(row, self._count(category_id), True)

    def delete(self, category_id: str) -> None:
        if self.repo.find(category_id) is None:
            raise NotFoundError("Category not found.")
        if self.repo.children(category_id):
            raise conflict("category_has_children", "Remove or move the sub-categories first.")
        n = self.repo.product_count([category_id], public_only=False)
        if n:
            raise conflict("category_in_use", f"{n} product(s) use this category. Deactivate it instead of deleting.")
        self.repo.delete(category_id)

    # ---------------- helpers ----------------
    def _check_parent(self, parent_id: str, kind: str, own_id: str | None) -> None:
        parent = self.repo.find(parent_id)
        if parent is None:
            raise unprocessable("invalid_parent", "Parent category does not exist.")
        if parent["kind"] != kind:
            raise unprocessable("invalid_parent", "A sub-category must have the same kind as its parent.")
        if own_id:
            rows = self.repo.list_all()
            if parent_id in descendants(rows, own_id):  # includes own_id itself
                raise unprocessable("invalid_parent", "A category cannot be placed under itself or its own sub-category.")

    def _unique_slug(self, name: str) -> str:
        base = slugify(name) or "category"
        taken = self.repo.slugs_like(base)
        if base not in taken:
            return base
        n = 2
        while f"{base}-{n}" in taken:
            n += 1
        return f"{base}-{n}"
