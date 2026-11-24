"""Backend-internal stock operations, prepared for checkout/order processing (a later step). No HTTP endpoint exposes it.
Uses the service-role client through the atomic SQL function public.adjust_product_stock (never negative, race-safe)."""
from app.core.exceptions import ValidationFailedError, conflict
from app.repositories.product_repository import ProductRepository


class InventoryService:
    def __init__(self, admin_db):
        self.products = ProductRepository(admin_db)

    def adjust(self, product_id: str, delta: int) -> int:
        if not isinstance(delta, int) or isinstance(delta, bool) or delta == 0:
            raise ValidationFailedError("delta must be a non-zero integer.")
        try:
            return self.products.adjust_stock(product_id, delta)
        except ValidationFailedError as exc:  # 23514 raised by the function
            raise conflict("insufficient_stock", "Not enough stock (or unknown product).") from exc
