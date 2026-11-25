from postgrest.types import CountMethod

from app.core.search import like_escape
from app.repositories.base import BaseRepository, Row


class CategoryRepository(BaseRepository):
    table = "categories"

    def __init__(self, client):
        super().__init__(client)

    def list_all(self, *, kind: str | None = None, parent_id: str | None = None, root_only: bool = False, active_only: bool = False) -> list[Row]:
        q = self.client.table(self.table).select("*")
        if active_only:
            q = q.eq("is_active", True)
        if kind:
            q = q.eq("kind", kind)
        if parent_id:
            q = q.eq("parent_id", parent_id)
        elif root_only:
            q = q.is_("parent_id", "null")
        return self._run(q.order("sort_order").order("name")).data

    def find(self, category_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", category_id).limit(1))
        return res.data[0] if res.data else None

    def name_taken(self, name: str, *, kind: str | None = None, exclude_id: str | None = None) -> bool:
        """Is there already a category with this name (case-insensitive, same kind)? Used to stop duplicates."""
        q = self.client.table(self.table).select("id,name").ilike("name", like_escape(name.strip()))
        if kind:
            q = q.eq("kind", kind)
        return any(r["id"] != exclude_id and r["name"].strip().lower() == name.strip().lower() for r in self._run(q.limit(10)).data)

    def children(self, parent_id: str) -> list[Row]:
        return self._run(self.client.table(self.table).select("id").eq("parent_id", parent_id)).data

    def product_count(self, category_ids: list[str], *, public_only: bool) -> int:
        q = self.client.table("products").select("id", count=CountMethod.exact, head=True).in_("category_id", category_ids)
        if public_only:  # RLS already restricts anon to this; stated explicitly for clarity/defence in depth
            q = q.eq("is_active", True).eq("approval_status", "approved")
        return self._run(q).count or 0

    def by_ids(self, ids: list[str]) -> list[Row]:
        if not ids:
            return []
        return self._run(self.client.table(self.table).select("*").in_("id", ids)).data

    def search_ids(self, pattern: str, limit: int = 20) -> list[str]:
        """Ids of (RLS-visible) categories whose name matches the already-escaped PostgREST pattern."""
        res = self._run(self.client.table(self.table).select("id").ilike("name", pattern).limit(limit))
        return [r["id"] for r in res.data]

    def slugs_like(self, base: str) -> set[str]:
        res = self._run(self.client.table(self.table).select("slug").ilike("slug", f"{base}*"))
        return {r["slug"] for r in res.data}
