from decimal import Decimal

from app.core.config import get_settings
from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict
from app.repositories.cart_repository import CartRepository
from app.repositories.product_repository import ProductRepository
from app.schemas.cart import CartItemAdd, CartItemUpdate
from app.services import _catalog
from app.services._shopping import availability, brief, money


class CartService:
    """Customer cart. Prices are always the CURRENT product price; stock is checked but NEVER reserved or reduced
    (reservation/deduction belongs to checkout, a later step). Products of several vendors may share one cart."""

    def __init__(self, db):
        self.db = db
        self.carts = CartRepository(db)
        self.products = ProductRepository(db)

    # ---------------- operations ----------------
    def view(self, user: CurrentUser) -> dict:
        return self._render(self._cart(user))

    def add(self, user: CurrentUser, data: CartItemAdd) -> tuple[dict, bool]:
        cart = self._cart(user)
        product = self.products.find(str(data.product_id))  # RLS: only publicly listed products are visible
        if product is None:
            raise NotFoundError("Product not found.")
        existing = self.carts.find_item_by_product(cart["id"], product["id"])
        quantity = data.quantity + (existing["quantity"] if existing else 0)
        self._check_can_hold(product, quantity)
        price = float(money(product["price"]))
        if existing:
            self.carts.update_item(cart["id"], existing["id"], {"quantity": quantity, "price_when_added": price})
        else:
            if len(self.carts.items(cart["id"])) >= get_settings().max_cart_items:
                raise conflict("cart_full", f"A cart can hold at most {get_settings().max_cart_items} different products.")
            self.carts.add_item({"cart_id": cart["id"], "product_id": product["id"], "quantity": quantity, "price_when_added": price})
        return self._render(cart), existing is None

    def update(self, user: CurrentUser, item_id, data: CartItemUpdate) -> dict:
        cart = self._cart(user)
        item = self._item(cart, item_id)
        product = self.products.find(item["product_id"])
        if product is None:
            raise conflict("not_listed", "This product is no longer available. Remove it from your cart.")
        self._check_can_hold(product, data.quantity)
        # saving the new quantity also acknowledges the current price
        self.carts.update_item(cart["id"], item["id"], {"quantity": data.quantity, "price_when_added": float(money(product["price"]))})
        return self._render(cart)

    def remove(self, user: CurrentUser, item_id) -> dict:
        cart = self._cart(user)
        item = self._item(cart, item_id)
        self.carts.delete_item(cart["id"], item["id"])
        return self._render(cart)

    def clear(self, user: CurrentUser) -> dict:
        cart = self._cart(user)
        self.carts.clear(cart["id"])
        return self._render(cart)

    # ---------------- internals ----------------
    def _cart(self, user: CurrentUser) -> dict:
        cart = self.carts.find_for_user(user.id)
        if cart is None:
            try:
                cart = self.carts.create_for_user(user.id)
            except Exception:  # noqa: BLE001 - lost a creation race (unique user_id): read the winner
                cart = self.carts.find_for_user(user.id)
                if cart is None:
                    raise
        return cart

    def _item(self, cart: dict, item_id) -> dict:
        item = self.carts.find_item(cart["id"], str(item_id))  # scoped to the caller's own cart
        if item is None:
            raise NotFoundError("Cart item not found.")
        return item

    @staticmethod
    def _check_can_hold(product: dict, quantity: int) -> None:
        status, stock = availability(product, quantity)
        if status == "not_listed":
            raise NotFoundError("Product not found.")
        if status == "unavailable":
            raise conflict("product_unavailable", "The seller has marked this product as unavailable.")
        if status == "out_of_stock":
            raise conflict("out_of_stock", "This product is out of stock.")
        if status == "insufficient_stock":
            raise conflict("insufficient_stock", f"Only {stock} unit(s) available; you asked for {quantity}.")

    def _render(self, cart: dict) -> dict:
        rows = self.carts.items(cart["id"])
        products = {p["id"]: p for p in self.products.find_many([r["product_id"] for r in rows])}
        ctx = _catalog.load_context(self.db, list(products.values()))
        items, groups = [], {}
        subtotal, qty_total = Decimal("0.00"), 0
        for r in rows:
            p = products.get(r["product_id"])
            status, stock = availability(p, r["quantity"])
            price = money(p["price"]) if p else None
            line = (price * r["quantity"]) if (p and status == "ok") else (price * r["quantity"] if p else None)
            before = money(r["price_when_added"]) if r.get("price_when_added") is not None else None
            changed = bool(p and before is not None and before != price)
            items.append({"id": r["id"], "product_id": r["product_id"], "quantity": r["quantity"], "product": brief(p, ctx),
                          "unit_price": price, "line_total": line, "status": status, "available_quantity": stock,
                          "price_changed": changed, "previous_price": before if changed else None})
            qty_total += r["quantity"]
            if status == "ok":
                subtotal += line
                vid = p["vendor_id"]
                g = groups.setdefault(vid, {"vendor_id": vid, "business_name": (ctx.vendors.get(vid) or {}).get("business_name"),
                                            "item_count": 0, "subtotal": Decimal("0.00")})
                g["item_count"] += 1
                g["subtotal"] += line
        return {"id": cart["id"], "items": items, "vendors": list(groups.values()),
                "summary": {"distinct_items": len(items), "total_quantity": qty_total, "subtotal": subtotal,
                            "multi_vendor": len(groups) > 1, "has_unavailable_items": any(i["status"] != "ok" for i in items),
                            "has_price_changes": any(i["price_changed"] for i in items)}}
