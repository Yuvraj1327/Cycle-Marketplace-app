from app.core.config import get_settings
from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict
from app.repositories.product_repository import ProductRepository
from app.repositories.wishlist_repository import WishlistRepository
from app.services import _catalog
from app.services._shopping import availability, brief


class WishlistService:
    """Private per-customer wishlist. A product must be publicly listed to be saved (out-of-stock is allowed:
    people save things to buy later). No duplicates: adding twice returns the existing entry."""

    def __init__(self, db):
        self.db = db
        self.lists = WishlistRepository(db)
        self.products = ProductRepository(db)

    def view(self, user: CurrentUser) -> dict:
        return self._render(self._wishlist(user))

    def add(self, user: CurrentUser, product_id) -> tuple[dict, bool]:
        wl = self._wishlist(user)
        product = self.products.find(str(product_id))
        if product is None:
            raise NotFoundError("Product not found.")
        existing = self.lists.find_item_by_product(wl["id"], product["id"])
        if existing:
            return self._item(existing, {product["id"]: product}, _catalog.load_context(self.db, [product])), False
        if len(self.lists.items(wl["id"])) >= get_settings().max_wishlist_items:
            raise conflict("wishlist_full", f"A wishlist can hold at most {get_settings().max_wishlist_items} products.")
        row = self.lists.add_item({"wishlist_id": wl["id"], "product_id": product["id"]})
        return self._item(row, {product["id"]: product}, _catalog.load_context(self.db, [product])), True

    def remove(self, user: CurrentUser, item_id) -> None:
        wl = self._wishlist(user)
        if self.lists.find_item(wl["id"], str(item_id)) is None:
            raise NotFoundError("Wishlist item not found.")
        self.lists.delete_item(wl["id"], str(item_id))

    def _wishlist(self, user: CurrentUser) -> dict:
        wl = self.lists.find_for_user(user.id)
        if wl is None:
            try:
                wl = self.lists.create_for_user(user.id)
            except Exception:  # noqa: BLE001 - creation race
                wl = self.lists.find_for_user(user.id)
                if wl is None:
                    raise
        return wl

    def _item(self, row: dict, products: dict, ctx) -> dict:
        p = products.get(row["product_id"])
        status, _ = availability(p, 1)
        return {"id": row["id"], "product_id": row["product_id"], "added_at": str(row["created_at"]), "product": brief(p, ctx), "status": status}

    def _render(self, wl: dict) -> dict:
        rows = self.lists.items(wl["id"])
        products = {p["id"]: p for p in self.products.find_many([r["product_id"] for r in rows])}
        ctx = _catalog.load_context(self.db, list(products.values()))
        return {"id": wl["id"], "items": [self._item(r, products, ctx) for r in rows], "total": len(rows)}
