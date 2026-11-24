"""Decimal-safe money helpers. Floats never take part in arithmetic: values arrive from PostgREST as JSON numbers, are
converted through str() to Decimal, rounded half-up to 2 places, and only converted back to float at the very edge (JSON)."""
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

CENT = Decimal("0.01")
ZERO = Decimal("0.00")


def D(value: Any) -> Decimal:
    return value if isinstance(value, Decimal) else Decimal(str(value))


def q2(value: Any) -> Decimal:
    return D(value).quantize(CENT, rounding=ROUND_HALF_UP)


def allocate(total: Decimal, weights: list[Decimal]) -> list[Decimal]:
    """Split `total` across `weights` in whole cents so the parts ALWAYS add up to `total` (largest-remainder method)."""
    total = q2(total)
    if not weights:
        return []
    weight_sum = sum(weights, Decimal(0))
    if weight_sum <= 0:
        shares = [Decimal(0)] * len(weights)
        shares[0] = total
        return shares
    raw = [total * w / weight_sum for w in weights]
    floors = [(r / CENT).to_integral_value(rounding="ROUND_FLOOR") * CENT for r in raw]
    remainder_cents = int(((total - sum(floors, Decimal(0))) / CENT).to_integral_value())
    order = sorted(range(len(weights)), key=lambda i: (raw[i] - floors[i], -i), reverse=True)
    for i in order[:remainder_cents]:
        floors[i] += CENT
    return floors
