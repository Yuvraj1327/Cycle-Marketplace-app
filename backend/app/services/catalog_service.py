"""Public marketplace browsing: listing, search, filters, sorting, detail, featured."""

from __future__ import annotations

from decimal import Decimal
from uuid import UUID

from app.core.exceptions import BadRequestError, NotFoundError
from app.core.search import contains_pattern, sanitize_term
from app.repositories.category_repository import CategoryRepository
from app.repositories.product_repository import ProductFilters, ProductRepository
from app.services import _catalog
from app.services.category_service import descendants


class CatalogService:
    def __init__(self, db):
        self.db = db
        self.products = ProductRepository(db)
        self.categories = CategoryRepository(db)

    def list(self, *, q: str | None, category_id: UUID | None, product_type: str | None, min_price: Decimal | None,
             max_price: Decimal | None, brand: str | None, condition: str | None, in_stock: bool | None,
             sort_by: str, page: int, limit: int) -> dict:
        if min_price is not None and max_price is not None and min_price > max_price:
            raise BadRequestError("min_price cannot be greater than max_price.")
        term = sanitize_term(q) if q else None
        brand_term = sanitize_term(brand, 100) if brand else None
        if (q and q.strip() and not term) or (brand and brand.strip() and not brand_term):
            return _catalog.page([], 0, page, limit)   # a search that reduces to nothing matches nothing (not everything)
        f = ProductFilters(
            q=term or None, product_type=product_type, min_price=min_price, max_price=max_price,
            brand=brand_term or None, condition=condition, in_stock=in_stock, public_only=True,
        )
        if term:
            f.q_category_ids = self.categories.search_ids(contains_pattern(term))   # "product category" search
        if category_id:
            f.category_ids = descendants(self.categories.list_all(active_only=True), str(category_id))
        rows, total = self.products.search(f, sort=sort_by, page=page, limit=limit)
        ctx = _catalog.load_context(self.db, rows)
        return _catalog.page([_catalog.summary(r, ctx) for r in rows], total, page, limit)

    def featured(self, limit: int) -> list[dict]:
        rows, _ = self.products.search(ProductFilters(is_featured=True, public_only=True), sort="newest", page=1, limit=limit)
        ctx = _catalog.load_context(self.db, rows)
        return [_catalog.summary(r, ctx) for r in rows]

    def detail(self, product_id: UUID) -> dict:
        row = self.products.find(str(product_id))
        # anon RLS already hides unapproved/inactive/suspended-vendor listings; checked again explicitly
        if row is None or not row["is_active"] or row["approval_status"] != "approved":
            raise NotFoundError("Product not found.")
        ctx = _catalog.load_context(self.db, [row], with_categories=True)
        return _catalog.detail(row, ctx)
