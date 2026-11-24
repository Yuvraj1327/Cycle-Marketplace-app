"""Read-only/helper endpoints added in Step 7 so the Customer App can show truthful checkout, booking and notification screens."""
import uuid

C = "/api/v1/checkout"
N = "/api/v1/notifications"


# ---------------- /checkout/options
def test_options_reflect_platform_configuration(client, world):
    r = client.get(C + "/options", headers=world.h)
    assert r.status_code == 200
    assert r.json() == {"cod_enabled": True, "online_enabled": True, "online_provider_configured": True, "multi_vendor_allowed": False, "delivery_charge": None, "currency": "INR"}
    world.db.tables["platform_settings"][0]["value"] = False
    world.db.rows("platform_settings").append({"key": "checkout.delivery_charge", "value": {"amount": 40, "free_above": 999, "per": "order"}})
    world.db.rows("platform_settings").append({"key": "checkout.multi_vendor_policy", "value": "allow_multi_vendor"})
    o = client.get(C + "/options", headers=world.h).json()
    assert o["cod_enabled"] is False and o["multi_vendor_allowed"] is True and o["delivery_charge"] == {"amount": 40, "free_above": 999, "per": "order"}


def test_online_is_only_offered_when_a_provider_is_configured(client, world):
    world.provider.configured = False
    o = client.get(C + "/options", headers=world.h).json()
    assert o["online_enabled"] is False and o["online_provider_configured"] is False
    world.provider.configured = True
    world.db.rows("platform_settings").append({"key": "payments.online_enabled", "value": False})
    assert client.get(C + "/options", headers=world.h).json()["online_enabled"] is False


def test_checkout_helper_endpoints_are_customer_only(client, world):
    body = {"delivery_address_id": world.addr["id"], "payment_method": "cod"}
    for h in ({}, world.ha, world.hva):
        assert client.get(C + "/options", headers=h).status_code in (401, 403)
        assert client.post(C + "/preview", json=body, headers=h).status_code in (401, 403)


# ---------------- /checkout/preview
def preview(client, world, **over):
    return client.post(C + "/preview", json={"delivery_address_id": world.addr["id"], "payment_method": "cod", **over}, headers=world.h)


def test_preview_matches_the_real_checkout_and_writes_nothing(client, world):
    world.db.rows("platform_settings").append({"key": "checkout.delivery_charge", "value": {"amount": 40, "free_above": None, "per": "order"}})
    world.db.rows("coupons").append(world.db.apply_defaults("coupons", {"id": "c0000000-0000-0000-0000-000000000009", "code": "SAVE10", "discount_type": "percentage",
                                                                       "discount_value": 10, "max_discount_amount": 50}))
    world.add(world.bike, 2)
    p = preview(client, world, coupon_code="save10")
    assert p.status_code == 200, p.text
    body = p.json()
    assert (body["subtotal"], body["delivery_charge"], body["discount_amount"], body["total_amount"]) == (2000, 40, 50, 1990)
    assert body["coupon_code"] == "SAVE10" and body["item_count"] == 2 and body["vendors"][0]["vendor_name"] == "Alpha" and body["vendors"][0]["total_amount"] == 1990
    assert not world.db.tables.get("orders") and world.bike["stock_quantity"] == 5 and len(world.db.tables["cart_items"]) == 1       # nothing reserved, cart intact
    assert world.db.tables["coupons"][0]["used_count"] == 0                                                                       # coupon not consumed
    real = world.checkout({"coupon_code": "SAVE10", "expected_total": 1990}).json()["order"]
    assert real["total_amount"] == body["total_amount"] and real["delivery_charge"] == body["delivery_charge"] and real["discount_amount"] == body["discount_amount"]


def test_preview_reports_the_same_problems_as_checkout(client, world):
    assert preview(client, world).json()["error"]["code"] == "empty_cart"
    world.add(world.bike, 6)
    assert preview(client, world).json()["error"]["code"] == "insufficient_stock"
    world.db.tables["cart_items"].clear(); world.add(world.bike); world.add(world.pads)
    assert preview(client, world).json()["error"]["code"] == "multi_vendor_checkout_not_allowed"
    assert preview(client, world, vendor_id=world.vb["id"]).json()["vendors"][0]["vendor_name"] == "Beta"
    assert preview(client, world, coupon_code="NOPE", vendor_id=world.vb["id"]).json()["error"]["code"] == "coupon_invalid"
    assert preview(client, world, delivery_address_id=str(uuid.uuid4())).json()["error"]["code"] == "invalid_address"
    assert preview(client, world, total_amount=1).status_code == 422                                  # amounts are never accepted from the client


def test_preview_ignores_expected_total_and_does_not_need_an_idempotency_key(client, world):
    world.add(world.bike)
    assert preview(client, world, expected_total=1).status_code == 200


# ---------------- /service-bookings/options
def test_booking_options(client, swd):
    O = "/api/v1/service-bookings/options"
    assert client.get(O, headers=swd.h).json() == {"pickup_charge": None, "dropoff_charge": None, "charges_configured": False, "min_notice_hours": 0, "max_advance_days": 60}
    swd.setting("services.pickup_charge", 40); swd.setting("services.dropoff_charge", 30); swd.setting("services.min_notice_hours", 2)
    o = client.get(O, headers=swd.h).json()
    assert (o["pickup_charge"], o["dropoff_charge"], o["charges_configured"], o["min_notice_hours"]) == (40, 30, True, 2)
    assert client.get(O).status_code == 401 and client.get(O, headers=swd.ha).status_code == 403


# ---------------- notifications
def seed(db, user, n=3, **kw):
    for i in range(n):
        db.rows("notifications").append(db.apply_defaults("notifications", {"user_id": user, "type": "order", "title": f"T{i}", "message": "m", "related_type": "order",
                                                                           "related_id": str(uuid.uuid4()), "is_read": False, "read_at": None, **kw}))


def test_notifications_list_unread_count_and_isolation(client, world):
    seed(world.db, world.cust, 3); seed(world.db, world.other, 2)
    world.db.tables["notifications"][0]["is_read"] = True
    r = client.get(N, headers=world.h).json()
    assert r["total"] == 3 and r["unread_count"] == 2 and [n["title"] for n in r["items"]] == ["T2", "T1", "T0"]
    assert client.get(N + "?unread_only=true", headers=world.h).json()["total"] == 2
    assert client.get(N + "?limit=1&page=2", headers=world.h).json()["items"][0]["title"] == "T1"
    assert client.get(N, headers=world.hother).json()["total"] == 2
    assert client.get(N).status_code == 401 and client.get(N + "?limit=0", headers=world.h).status_code == 422


def test_mark_read_only_for_the_owner(client, world):
    seed(world.db, world.cust, 2); seed(world.db, world.other, 1)
    mine, theirs = world.db.tables["notifications"][0], world.db.tables["notifications"][2]
    r = client.post(f"{N}/{mine['id']}/read", headers=world.h)
    assert r.status_code == 200 and r.json()["is_read"] is True and mine["is_read"] is True
    assert client.post(f"{N}/{theirs['id']}/read", headers=world.h).status_code == 404 and theirs["is_read"] is False
    assert client.post(f"{N}/{uuid.uuid4()}/read", headers=world.h).status_code == 404 and client.post(f"{N}/nope/read", headers=world.h).status_code == 422


def test_mark_all_read_touches_only_own_notifications(client, world):
    seed(world.db, world.cust, 3); seed(world.db, world.other, 2)
    assert client.post(N + "/read-all", headers=world.h).json() == {"marked_read": 3}
    assert client.get(N, headers=world.h).json()["unread_count"] == 0 and client.get(N, headers=world.hother).json()["unread_count"] == 2
    assert client.post(N + "/read-all", headers=world.h).json() == {"marked_read": 0}


def test_every_role_can_read_its_own_notifications(client, world):
    seed(world.db, world.ua, 1); seed(world.db, world.admin, 1)
    assert client.get(N, headers=world.hva).json()["total"] == 1 and client.get(N, headers=world.ha).json()["total"] == 1
