"""Settings used by servicing. Pickup/drop-off charges are NEVER invented: when unset the booking records 0 and says so explicitly."""
from dataclasses import dataclass
from decimal import Decimal

from app.core.money import q2
from app.services.checkout_settings import DROPOFF_CHARGE, MAX_ADVANCE, MIN_NOTICE, PICKUP_CHARGE

KEYS = [PICKUP_CHARGE, DROPOFF_CHARGE, MIN_NOTICE, MAX_ADVANCE]


@dataclass(frozen=True)
class ServiceSettings:
    pickup_charge: Decimal | None = None
    dropoff_charge: Decimal | None = None
    min_notice_hours: int = 0
    max_advance_days: int = 60

    @property
    def charges_configured(self) -> bool:
        return self.pickup_charge is not None and self.dropoff_charge is not None


def load_service_settings(raw: dict) -> ServiceSettings:
    def amount(v):
        return q2(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v <= 100000 else None

    def whole(v, low, high, default):
        return v if isinstance(v, int) and not isinstance(v, bool) and low <= v <= high else default

    return ServiceSettings(amount(raw.get(PICKUP_CHARGE)), amount(raw.get(DROPOFF_CHARGE)), whole(raw.get(MIN_NOTICE), 0, 168, 0), whole(raw.get(MAX_ADVANCE), 1, 365, 60))
