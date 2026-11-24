from typing import Annotated, Any
from uuid import UUID

from pydantic import BaseModel, Field, StringConstraints

from app.schemas.common import Money, StrictModel
from app.schemas.order import OrderDetailOut, PaymentMethod
from app.schemas.payment import PaymentOut
from app.schemas.product import MoneyIn


class CheckoutRequest(StrictModel):
    """Only choices, never amounts: prices, discounts, delivery, commission and totals are computed on the server."""

    delivery_address_id: UUID
    payment_method: PaymentMethod
    coupon_code: Annotated[str, StringConstraints(min_length=2, max_length=40, pattern=r"^[A-Za-z0-9_\-]+$")] | None = None
    customer_note: Annotated[str, StringConstraints(max_length=500)] | None = None
    vendor_id: UUID | None = Field(None, description="Check out only this seller's items (leaves the rest in the cart).")
    expected_total: MoneyIn | None = Field(None, description="The total the customer saw. NOT trusted: if it differs from the server total the request is refused so the customer can re-confirm.")
    accept_price_changes: bool = False


class CheckoutOut(BaseModel):
    order: OrderDetailOut
    payment: PaymentOut
    client_payload: dict[str, Any] | None = None
    replay: bool = False


class PricePreview(BaseModel):
    subtotal: Money
    delivery_charge: Money
    discount_amount: Money
    total_amount: Money
