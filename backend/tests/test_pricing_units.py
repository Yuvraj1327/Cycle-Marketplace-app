import random
from datetime import datetime, timedelta, timezone
from decimal import Decimal as D

import pytest

from app.core.exceptions import ValidationFailedError
from app.core.money import allocate, q2
from app.services import _pricing as pr
from app.services.checkout_settings import DeliveryRule, load_settings, validate_setting

NOW = datetime(2026, 6, 1, tzinfo=timezone.utc)


def coupon(**kw):
    return {"is_active": True, "discount_type": "percentage", "discount_value": 10, "max_discount_amount": None, "min_order_amount": 0, "applies_to": "all",
            "used_count": 0, "usage_limit": None, "per_user_limit": None, "valid_from": "2026-01-01T00:00:00+00:00", "valid_until": None, **kw}


def test_money_never_uses_binary_floats():
    assert q2(0.1) + q2(0.2) == D("0.30") and q2("2.675") == D("2.68") and q2(1.005) == D("1.01")


def test_allocation_always_sums_exactly():
    rnd = random.Random(7)
    for _ in range(3000):
        total = q2(rnd.randint(0, 5_000_000) / 100)
        weights = [D(rnd.randint(1, 99999)) / 100 for _ in range(rnd.randint(1, 7))]
        parts = allocate(total, weights)
        assert sum(parts) == total and all(p >= 0 for p in parts) and len(parts) == len(weights)
    assert allocate(D("0.01"), [D(1), D(1), D(1)]).count(D("0.01")) == 1


def test_discount_rules():
    assert pr.discount_amount(coupon(), D("999.99")) == D("100.00")
    assert pr.discount_amount(coupon(max_discount_amount=50), D("1000")) == D("50.00")
    assert pr.discount_amount(coupon(discount_type="fixed", discount_value=500), D("300")) == D("300.00")      # never above goods value


@pytest.mark.parametrize("kw,uses,reason", [({"is_active": False}, 0, "inactive"), ({"valid_from": "2099-01-01T00:00:00+00:00"}, 0, "not_started"),
                                            ({"valid_until": "2026-05-01T00:00:00+00:00"}, 0, "expired"), ({"applies_to": "services"}, 0, "not_for_products"),
                                            ({"min_order_amount": 5000}, 0, "below_minimum_order"), ({"usage_limit": 3, "used_count": 3}, 0, "usage_limit_reached"),
                                            ({"per_user_limit": 1}, 1, "already_used"), ({}, 0, None)])
def test_coupon_problems(kw, uses, reason):
    assert pr.coupon_problem(coupon(**kw), D("1000"), uses, NOW) == reason


def test_delivery_charges():
    rule = DeliveryRule(D("50"), D("1000"), "order")
    assert pr.delivery_charges(None, [D(10)]) == [D("0.00")]
    assert pr.delivery_charges(rule, [D("1000")]) == [D("0.00")]                         # free at threshold
    assert sum(pr.delivery_charges(rule, [D("333"), D("333"), D("1")])) == D("50.00")
    assert pr.delivery_charges(DeliveryRule(D("50"), None, "vendor_order"), [D(1), D(2)]) == [D("50"), D("50")]


def rule(**kw):
    return {"id": kw.pop("id", "r"), "is_active": True, "priority": 0, "vendor_id": None, "category_id": None, "effective_from": "2026-01-01T00:00:00+00:00",
            "effective_until": None, "commission_type": "percentage", "commission_value": 10, "created_at": "2026-01-01", **kw}


def test_commission_rule_selection_order():
    g, c, v, vc = rule(id="g"), rule(id="c", category_id="cat"), rule(id="v", vendor_id="V"), rule(id="vc", vendor_id="V", category_id="cat")
    assert pr.select_commission_rule([g], "V", "cat", NOW)["id"] == "g"
    assert pr.select_commission_rule([g, c], "V", "cat", NOW)["id"] == "c"
    assert pr.select_commission_rule([g, c, v], "V", "cat", NOW)["id"] == "v"          # vendor beats category
    assert pr.select_commission_rule([g, c, v, vc], "V", "cat", NOW)["id"] == "vc"
    assert pr.select_commission_rule([c, v], "OTHER", "other", NOW) is None
    assert pr.select_commission_rule([rule(id="hi", priority=9), rule(id="lo", priority=1)], "V", "cat", NOW)["id"] == "hi"
    assert pr.select_commission_rule([rule(is_active=False)], "V", "cat", NOW) is None
    assert pr.select_commission_rule([rule(effective_until="2026-05-01T00:00:00+00:00")], "V", "cat", NOW) is None
    assert pr.select_commission_rule([rule(effective_from=(NOW + timedelta(days=1)).isoformat())], "V", "cat", NOW) is None


def test_commission_amounts():
    assert pr.commission_for_line(rule(commission_value=7.5), D("333.33"), 3) == D("75.00")
    assert pr.commission_for_line(rule(commission_type="fixed", commission_value=7), D("100"), 3) == D("21.00")
    assert pr.commission_for_line(rule(commission_type="fixed", commission_value=500), D("100"), 1) == D("100.00")   # capped at the line value


def test_settings_defaults_and_validation():
    d = load_settings({})
    assert (d.cod_enabled, d.online_enabled, d.multi_vendor_policy, d.delivery, d.missing_commission_policy, d.payment_window_minutes) == (False, True, None, None, "block", 30)
    assert load_settings({"checkout.payment_window_minutes": 9999, "payments.cod_enabled": 1}).payment_window_minutes == 30
    assert validate_setting("checkout.delivery_charge", {"amount": 10, "per": "order"})["free_above"] is None
    with pytest.raises(ValidationFailedError):
        validate_setting("payments.cod_enabled", "true")
