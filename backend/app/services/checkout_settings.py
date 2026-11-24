"""Platform settings that drive checkout/payment behaviour. All are read with the service client (non-public keys) and
validated: malformed values fall back to the SAFE default instead of crashing or inventing business rules."""
import logging
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from app.core.exceptions import unprocessable
from app.core.money import q2

logger = logging.getLogger(__name__)

COD_ENABLED = "payments.cod_enabled"
ONLINE_ENABLED = "payments.online_enabled"
MULTI_VENDOR_POLICY = "checkout.multi_vendor_policy"
DELIVERY_CHARGE = "checkout.delivery_charge"
MISSING_COMMISSION = "commission.missing_rule_policy"
PAYMENT_WINDOW = "checkout.payment_window_minutes"
LISTING_APPROVAL = "marketplace.require_listing_approval"
PICKUP_CHARGE = "services.pickup_charge"
DROPOFF_CHARGE = "services.dropoff_charge"
MIN_NOTICE = "services.min_notice_hours"
MAX_ADVANCE = "services.max_advance_days"

MULTI_VENDOR_VALUES = ("single_vendor_only", "allow_multi_vendor")
MISSING_COMMISSION_VALUES = ("block", "zero")

DESCRIPTIONS = {
    COD_ENABLED: "Customers may pay cash on delivery (default: off).",
    ONLINE_ENABLED: "Customers may pay online (also needs a configured payment provider; default: on).",
    MULTI_VENDOR_POLICY: "single_vendor_only | allow_multi_vendor. Unset = one vendor per checkout (client decision pending).",
    DELIVERY_CHARGE: '{"amount": 50, "free_above": 1000 | null, "per": "order" | "vendor_order"}. Unset = no delivery charge.',
    MISSING_COMMISSION: "block | zero - what to do when no commission rule matches an item (default: block).",
    PAYMENT_WINDOW: "Minutes an unpaid online order keeps its stock reserved (5-1440, default 30).",
    LISTING_APPROVAL: "Whether new product listings need admin approval (default: yes).",
    PICKUP_CHARGE: "Doorstep pickup charge (amount >= 0). Unset = no amount configured (bookings show charges as not configured, recorded as 0).",
    DROPOFF_CHARGE: "Doorstep drop-off charge (amount >= 0). Unset = no amount configured.",
    MIN_NOTICE: "Minimum hours between booking and the appointment slot (0-168, default 0).",
    MAX_ADVANCE: "How many days ahead a service can be booked (1-365, default 60).",
}


@dataclass(frozen=True)
class DeliveryRule:
    amount: Decimal
    free_above: Decimal | None
    per: str  # "order" | "vendor_order"


@dataclass(frozen=True)
class CheckoutSettings:
    cod_enabled: bool = False
    online_enabled: bool = True
    multi_vendor_policy: str | None = None
    delivery: DeliveryRule | None = None
    missing_commission_policy: str = "block"
    payment_window_minutes: int = 30

    @property
    def multi_vendor_allowed(self) -> bool:
        return self.multi_vendor_policy == "allow_multi_vendor"


def parse_delivery(value: Any) -> DeliveryRule:
    if not isinstance(value, dict) or set(value) - {"amount", "free_above", "per"}:
        raise ValueError("expected an object with amount, free_above and per")
    amount = q2(value["amount"])
    free_above = q2(value["free_above"]) if value.get("free_above") is not None else None
    per = value.get("per", "order")
    if amount < 0 or (free_above is not None and free_above < 0) or per not in ("order", "vendor_order"):
        raise ValueError("amount/free_above must be >= 0 and per must be 'order' or 'vendor_order'")
    return DeliveryRule(amount, free_above, per)


def validate_setting(key: str, value: Any) -> Any:
    """Validation for admin writes. Returns the value to store; raises 422 otherwise."""
    try:
        if key in (COD_ENABLED, ONLINE_ENABLED, LISTING_APPROVAL):
            if not isinstance(value, bool):
                raise ValueError("must be true or false")
            return value
        if key == MULTI_VENDOR_POLICY:
            if value not in MULTI_VENDOR_VALUES:
                raise ValueError(f"must be one of {MULTI_VENDOR_VALUES}")
            return value
        if key == MISSING_COMMISSION:
            if value not in MISSING_COMMISSION_VALUES:
                raise ValueError(f"must be one of {MISSING_COMMISSION_VALUES}")
            return value
        if key == PAYMENT_WINDOW:
            if isinstance(value, bool) or not isinstance(value, int) or not 5 <= value <= 1440:
                raise ValueError("must be a whole number of minutes between 5 and 1440")
            return value
        if key in (PICKUP_CHARGE, DROPOFF_CHARGE):
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0 or value > 100000:
                raise ValueError("must be an amount between 0 and 100000")
            return float(q2(value))
        if key in (MIN_NOTICE, MAX_ADVANCE):
            low, high = (0, 168) if key == MIN_NOTICE else (1, 365)
            if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
                raise ValueError(f"must be a whole number between {low} and {high}")
            return value
        if key == DELIVERY_CHARGE:
            rule = parse_delivery(value)
            return {"amount": float(rule.amount), "free_above": float(rule.free_above) if rule.free_above is not None else None, "per": rule.per}
    except (ValueError, KeyError, TypeError, ArithmeticError) as exc:
        raise unprocessable("invalid_setting", f"{key}: {exc}") from exc
    raise unprocessable("unknown_setting", f"'{key}' is not a manageable setting.")


def load_settings(raw: dict[str, Any]) -> CheckoutSettings:
    def pick(key, check, default):
        if key not in raw:
            return default
        try:
            return check(raw[key])
        except (ValueError, KeyError, TypeError, ArithmeticError):
            logger.warning("ignoring malformed platform setting %s", key)
            return default

    def boolean(v):
        if not isinstance(v, bool):
            raise ValueError
        return v

    def one_of(options):
        def check(v):
            if v not in options:
                raise ValueError
            return v
        return check

    def window(v):
        if isinstance(v, bool) or not isinstance(v, int) or not 5 <= v <= 1440:
            raise ValueError
        return v

    return CheckoutSettings(
        cod_enabled=pick(COD_ENABLED, boolean, False),
        online_enabled=pick(ONLINE_ENABLED, boolean, True),
        multi_vendor_policy=pick(MULTI_VENDOR_POLICY, one_of(MULTI_VENDOR_VALUES), None),
        delivery=pick(DELIVERY_CHARGE, parse_delivery, None),
        missing_commission_policy=pick(MISSING_COMMISSION, one_of(MISSING_COMMISSION_VALUES), "block"),
        payment_window_minutes=pick(PAYMENT_WINDOW, window, 30),
    )


ALL_KEYS = list(DESCRIPTIONS)


