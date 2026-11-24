from dataclasses import dataclass, field
from decimal import Decimal

from postgrest.types import CountMethod

from app.core.search import contains_pattern, like_escape
from app.repositories.base import BaseRepository, Row


@dataclass
class ProductFilters:
    q: str | None = None                       # already sanitized
    q_category_ids: list[str] = field(default_factory=list)  # categories whose NAME matched q
    category_ids: list[str] | None = None
    product_type: str | None = None
    min_price: Decimal | None = None
    max_price: Decimal | None = None
    brand: str | None = None                   # already sanitized
    condition: str | None = None
    in_stock: bool | None = None
    vendor_id: str | None = None
    approval_status: str | None = None
    is_active: bool | None = None
    is_featured: bool | None = None
    public_only: bool = False


SORTS: dict[str, list[tuple[str, bool]]] = {   # (column, desc); id is a stable tiebreaker for pagination
    "relevance": [("is_featured", True), ("created_at", True), ("id", False)],
    "newest": [("created_at", True), ("id", False)],
    "price_low_to_high": [("price", False), ("created_at", True), ("id", False)],
    "price_high_to_low": [("price", True), ("created_at", True), ("id", False)],
}


class ProductRepository(BaseRepository):
    table = "products"

    def __init__(self, client):
        super().__init__(client)

    # ---- search / listing -------------------------------------------------------------
    def search(self, f: ProductFilters, *, sort: str, page: int, limit: int) -> tuple[list[Row], int]:
        q = self.client.table(self.table).select("*", count=CountMethod.exact)
        if f.public_only:
            q = q.eq("is_active", True).eq("approval_status", "approved")
        if f.is_active is not None:
            q = q.eq("is_active", f.is_active)
        if f.approval_status:
            q = q.eq("approval_status", f.approval_status)
        if f.is_featured is not None:
            q = q.eq("is_featured", f.is_featured)
        if f.vendor_id:
            q = q.eq("vendor_id", f.vendor_id)
        if f.category_ids:
            q = q.in_("category_id", f.category_ids)
        if f.product_type:
            q = q.eq("product_type", f.product_type)
        if f.condition:
            q = q.eq("condition", f.condition)
        if f.min_price is not None:
            q = q.gte("price", float(f.min_price))
        if f.max_price is not None:
            q = q.lte("price", float(f.max_price))
        if f.brand:
            q = q.ilike("brand", like_escape(f.brand))
        if f.in_stock is True:
            q = q.eq("is_available", True).gt("stock_quantity", 0)
        elif f.in_stock is False:
            q = q.or_("is_available.eq.false,stock_quantity.eq.0")
        if f.q:
            pat = contains_pattern(f.q)  # q is sanitized upstream; pattern characters are escaped as well
            clauses = [f"name.ilike.{pat}", f"brand.ilike.{pat}", f"model.ilike.{pat}", f"description.ilike.{pat}"]
            if f.q_category_ids:
                clauses.append(f"category_id.in.({','.join(f.q_category_ids)})")  # ids come from the database
            q = q.or_(",".join(clauses))
        for column, desc in SORTS[sort]:
            q = q.order(column, desc=desc)
        offset = (page - 1) * limit
        res = self._run(q.range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find(self, product_id: str, *, vendor_id: str | None = None) -> Row | None:
        q = self.client.table(self.table).select("*").eq("id", product_id)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        res = self._run(q.limit(1))
        return res.data[0] if res.data else None

    def find_many(self, product_ids: list[str]) -> list[Row]:
        if not product_ids:
            return []
        return self._run(self.client.table(self.table).select("*").in_("id", product_ids)).data

    def insert(self, values: Row) -> Row:
        return self.create(values)

    def modify(self, product_id: str, values: Row, *, vendor_id: str | None = None) -> Row | None:
        q = self.client.table(self.table).update(values).eq("id", product_id)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        res = self._run(q)
        return res.data[0] if res.data else None

    def remove(self, product_id: str, *, vendor_id: str) -> None:
        self._run(self.client.table(self.table).delete().eq("id", product_id).eq("vendor_id", vendor_id))

    def has_orders(self, product_id: str) -> bool:
        return bool(self._run(self.client.table("order_items").select("id").eq("product_id", product_id).limit(1)).data)

    def adjust_stock(self, product_id: str, delta: int) -> int:
        """Atomic, never-negative stock change (SQL function, service-role only). For backend order processing."""
        return self._run(self.client.rpc("adjust_product_stock", {"p_product_id": product_id, "p_delta": delta})).data
