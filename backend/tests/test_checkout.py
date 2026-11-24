import uuid

C = "/api/v1/checkout"


def test_requires_customer_and_idempotency_key(client, world):
    world.add(world.bike)
    body = {"delivery_address_id": world.addr["id"], "payment_method": "cod"}
    assert client.post(C, json=body).status_code == 401
    for h in (world.ha, world.hva):
        assert client.post(C, json=body, headers={**h, "Idempotency-Key": "abcdefgh1"}).status_code == 403
    assert client.post(C, json=body, headers=world.h).status_code == 422                                        # header missing
    assert client.post(C, json=body, headers={**world.h, "Idempotency-Key": "short"}).status_code == 422
    assert not world.db.tables.get("orders")


def test_cod_checkout_server_computes_everything(client, world):
    world.add(world.bike, 2)
    r = world.checkout({"payment_method": "cod"})
    assert r.status_code == 201, r.text
    body = r.json()
    o, pay = body["order"], body["payment"]
    assert o["status"] == "confirmed" and o["payment_status"] == "pending" and o["payment_method"] == "cod"
    assert (o["subtotal"], o["delivery_charge"], o["discount_amount"], o["total_amount"]) == (2000, 0, 0, 2000)
    assert pay["method"] == "cod" and pay["status"] == "pending" and pay["amount"] == 2000 and pay["amount_due"] == 2000
    assert body["client_payload"] is None and body["replay"] is False
    vo = o["vendor_orders"][0]
    assert vo["vendor_name"] == "Alpha" and vo["status"] == "pending" and vo["items"][0]["unit_price"] == 1000 and vo["items"][0]["quantity"] == 2
    assert o["delivery_address"]["city"] == "Pune" and o["can_cancel"] is True
    assert world.bike["stock_quantity"] == 3                                    # reserved
    assert world.db.tables["cart_items"] == []                                  # purchased lines leave the cart
    row = world.db.tables["vendor_orders"][0]
    assert row["commission_amount"] == 200.0                                    # 10% rule snapshot


def test_amounts_in_the_request_are_rejected_not_trusted(client, world):
    world.add(world.bike)
    for bad in ({"total_amount": 1}, {"subtotal": 1}, {"discount_amount": 999}, {"delivery_charge": 0}, {"vendor_orders": []}, {"customer_id": world.other}):
        assert world.checkout(bad).status_code == 422, bad
    assert not world.db.tables.get("orders")


def test_prices_come_from_the_database_not_the_cart(client, world):
    world.add(world.bike)
    world.db.tables["cart_items"][0]["price_when_added"] = 1.0                  # tampered snapshot is only informational
    r = world.checkout({"accept_price_changes": True})
    assert r.status_code == 201 and r.json()["order"]["total_amount"] == 1000


def test_empty_cart(client, world):
    r = world.checkout()
    assert r.status_code == 409 and r.json()["error"]["code"] == "empty_cart"


def test_unavailable_products_block_checkout_with_details(client, world):
    world.add(world.bike); world.add(world.pads)
    world.bike["is_active"] = False
    r = world.checkout()
    assert r.status_code == 409 and r.json()["error"]["code"] == "product_unavailable"
    assert r.json()["error"]["details"][0]["product_id"] == world.bike["id"]
    world.bike["is_active"] = True; world.pads["is_available"] = False
    assert world.checkout().json()["error"]["code"] == "product_unavailable"
    world.pads["is_available"] = True; world.pads["approval_status"] = "rejected"
    assert world.checkout().json()["error"]["code"] == "product_unavailable"
    assert not world.db.tables.get("orders") and world.bike["stock_quantity"] == 5


def test_insufficient_stock_and_multiple_issues(client, world):
    world.add(world.bike, 5)
    world.bike["stock_quantity"] = 2
    r = world.checkout()
    assert r.status_code == 409 and r.json()["error"]["code"] == "insufficient_stock" and r.json()["error"]["details"][0]["available_quantity"] == 2
    world.add(world.pads, 1); world.pads["stock_quantity"] = 0
    r = world.checkout({"vendor_id": None})
    assert r.json()["error"]["code"] == "checkout_validation_failed" and len(r.json()["error"]["details"]) == 2


def test_price_changed_since_added_requires_confirmation(client, world):
    world.add(world.bike)
    world.bike["price"] = 1200.0
    r = world.checkout()
    assert r.status_code == 409 and r.json()["error"]["code"] == "price_changed"
    assert r.json()["error"]["details"][0]["previous_price"] == 1000 and r.json()["error"]["details"][0]["current_price"] == 1200
    ok = world.checkout({"accept_price_changes": True})
    assert ok.status_code == 201 and ok.json()["order"]["total_amount"] == 1200


def test_expected_total_is_only_a_consistency_check(client, world):
    world.add(world.bike)
    r = world.checkout({"expected_total": 900})
    assert r.status_code == 409 and r.json()["error"]["code"] == "price_changed" and r.json()["error"]["details"][0]["current_total"] == 1000
    assert world.checkout({"expected_total": 1000}).status_code == 201


def test_invalid_delivery_address(client, world):
    world.add(world.bike)
    assert world.checkout({"delivery_address_id": str(uuid.uuid4())}).json()["error"]["code"] == "invalid_address"
    foreign = world.db.apply_defaults("user_addresses", {"user_id": world.other, "recipient_name": "X", "phone": "+919800000002", "address_line1": "a", "city": "c",
                                                         "state": "s", "postal_code": "411001", "address_type": "both"})
    world.db.rows("user_addresses").append(foreign)
    assert world.checkout({"delivery_address_id": foreign["id"]}).json()["error"]["code"] == "invalid_address"      # someone else's address
    world.addr["address_type"] = "pickup"
    assert world.checkout().json()["error"]["code"] == "invalid_address"
    assert not world.db.tables.get("orders")


def test_duplicate_checkout_requests_create_one_order(client, world):
    world.add(world.bike, 2)
    first = world.checkout(key="same-key-0001")
    again = world.checkout(key="same-key-0001")
    assert first.status_code == 201 and again.status_code == 200 and again.json()["replay"] is True
    assert again.json()["order"]["id"] == first.json()["order"]["id"]
    assert len(world.db.tables["orders"]) == 1 and world.bike["stock_quantity"] == 3     # stock deducted once
    other = world.checkout({"customer_note": "different"}, key="same-key-0001")
    assert other.status_code == 409 and other.json()["error"]["code"] == "idempotency_key_reuse"


def test_replay_survives_the_cart_being_emptied(client, world):
    world.add(world.bike)
    world.checkout(key="replay-key-01")
    assert world.db.tables["cart_items"] == []
    assert world.checkout(key="replay-key-01").status_code == 200       # not "empty cart"


def test_cod_must_be_enabled_by_admin(client, world):
    world.add(world.bike)
    world.db.tables["platform_settings"].clear()
    r = world.checkout()
    assert r.status_code == 409 and r.json()["error"]["code"] == "cod_not_available"
    world.db.rows("platform_settings").append({"key": "payments.cod_enabled", "value": "yes"})       # malformed => still off
    assert world.checkout().json()["error"]["code"] == "cod_not_available"
    world.db.tables["platform_settings"][0]["value"] = True
    assert world.checkout().status_code == 201


def test_multi_vendor_policy_unset_refuses_ambiguous_cart(client, world):
    world.add(world.bike); world.add(world.pads)
    r = world.checkout()
    assert r.status_code == 409 and r.json()["error"]["code"] == "multi_vendor_checkout_not_allowed"
    assert {d["business_name"] for d in r.json()["error"]["details"]} == {"Alpha", "Beta"}
    assert not world.db.tables.get("orders") and world.bike["stock_quantity"] == 5


def test_single_vendor_checkout_from_a_mixed_cart_leaves_the_rest(client, world):
    world.add(world.bike); world.add(world.pads)
    r = world.checkout({"vendor_id": world.vb["id"]})
    assert r.status_code == 201 and [v["vendor_name"] for v in r.json()["order"]["vendor_orders"]] == ["Beta"]
    assert [i["product_id"] for i in world.db.tables["cart_items"]] == [world.bike["id"]]
    assert world.bike["stock_quantity"] == 5 and world.pads["stock_quantity"] == 3


def test_multi_vendor_allowed_by_setting_splits_one_order_into_vendor_orders(client, world):
    world.db.rows("platform_settings").append({"key": "checkout.multi_vendor_policy", "value": "allow_multi_vendor"})
    world.db.rows("platform_settings").append({"key": "checkout.delivery_charge", "value": {"amount": 100, "free_above": None, "per": "order"}})
    world.add(world.bike); world.add(world.pads, 2)
    r = world.checkout({"payment_method": "cod"})
    o = r.json()["order"]
    assert r.status_code == 201 and o["vendor_count"] == 2 and len(o["vendor_orders"]) == 2
    assert o["subtotal"] == 1501 and o["delivery_charge"] == 100 and o["total_amount"] == 1601
    assert sum(v["total_amount"] for v in o["vendor_orders"]) == o["total_amount"]            # allocation adds up exactly
    assert sum(v["delivery_charge"] for v in o["vendor_orders"]) == 100


def test_delivery_charge_free_above_and_per_vendor_order(client, world):
    s = world.db.rows("platform_settings")
    s.append({"key": "checkout.delivery_charge", "value": {"amount": 40, "free_above": 1500, "per": "order"}})
    world.add(world.pads)
    assert world.checkout().json()["order"]["delivery_charge"] == 40
    world.add(world.bike, 2)
    world.db.tables["cart_items"] = [i for i in world.db.tables["cart_items"]]
    world.add(world.bike, 1)
    s[-1]["value"] = {"amount": 40, "free_above": 500, "per": "order"}
    world.add(world.bike)
    assert world.checkout({"vendor_id": world.va["id"]}).json()["order"]["delivery_charge"] == 0


def test_coupon_discount_and_validation(client, world):
    world.db.rows("coupons").append(world.db.apply_defaults("coupons", {"id": "c0000000-0000-0000-0000-000000000001", "code": "SAVE10", "discount_type": "percentage",
                                                                       "discount_value": 10, "max_discount_amount": 50, "min_order_amount": 500, "usage_limit": 1}))
    world.add(world.bike)
    r = world.checkout({"coupon_code": "save10"})
    o = r.json()["order"]
    assert r.status_code == 201 and o["discount_amount"] == 50 and o["total_amount"] == 950 and o["coupon_code"] == "SAVE10"
    world.add(world.bike)
    again = world.checkout({"coupon_code": "SAVE10"})
    assert again.status_code == 422 and again.json()["error"]["details"][0]["reason"] == "usage_limit_reached"
    assert world.checkout({"coupon_code": "NOPE"}).json()["error"]["details"][0]["reason"] == "not_found"
    world.db.tables["coupons"][0].update(usage_limit=None, used_count=0, min_order_amount=5000)
    assert world.checkout({"coupon_code": "SAVE10"}).json()["error"]["details"][0]["reason"] == "below_minimum_order"
    world.db.tables["coupons"][0].update(min_order_amount=0, valid_until="2020-06-01T00:00:00+00:00")
    assert world.checkout({"coupon_code": "SAVE10"}).json()["error"]["details"][0]["reason"] == "expired"
    assert client.post(C, json={"delivery_address_id": world.addr["id"], "payment_method": "cod", "coupon_code": "bad code!"}, headers={**world.h, "Idempotency-Key": "xxxxxxxx1"}).status_code == 422


def test_commission_rule_specificity_and_missing_rule_policy(client, world):
    rules = world.db.rows("commission_rules")
    rules.append(world.db.apply_defaults("commission_rules", {"name": "Alpha only", "applies_to": "product", "commission_type": "percentage", "commission_value": 5, "vendor_id": world.va["id"]}))
    rules.append(world.db.apply_defaults("commission_rules", {"name": "Parts", "applies_to": "product", "commission_type": "fixed", "commission_value": 7, "category_id": world.parts["id"]}))
    world.db.rows("platform_settings").append({"key": "checkout.multi_vendor_policy", "value": "allow_multi_vendor"})
    world.add(world.bike, 2); world.add(world.pads, 3)
    assert world.checkout().status_code == 201
    vos = {v["vendor_id"]: v for v in world.db.tables["vendor_orders"]}
    assert vos[world.va["id"]]["commission_amount"] == 100.0       # vendor rule (5%) beats the global 10%: 2000 * 5%
    assert vos[world.vb["id"]]["commission_amount"] == 21.0        # category rule: fixed 7 per unit x 3
    # no matching rule at all
    world.db.tables["commission_rules"].clear()
    world.add(world.bike)
    r = world.checkout({"vendor_id": world.va["id"]})
    assert r.status_code == 503 and r.json()["error"]["code"] == "commission_not_configured" and world.bike["stock_quantity"] == 3
    world.db.rows("platform_settings").append({"key": "commission.missing_rule_policy", "value": "zero"})
    assert world.checkout({"vendor_id": world.va["id"]}).status_code == 201
    assert world.db.tables["vendor_orders"][-1]["commission_amount"] == 0.0


def test_payload_sent_to_the_database_is_fully_server_computed(client, world):
    world.add(world.bike, 2)
    world.checkout()
    fn, params = world.db.sql.calls[-1]
    p = params["p"]
    assert fn == "place_order" and p["customer_id"] == world.cust and p["total_amount"] == "2000.00" and p["subtotal"] == "2000.00"
    assert p["vendor_orders"][0]["items"][0]["unit_price"] == "1000.00" and p["vendor_orders"][0]["commission_amount"] == "200.00"
    assert all(isinstance(p[k], str) for k in ("subtotal", "delivery_charge", "discount_amount", "total_amount"))     # exact decimals, no floats


def test_online_checkout_without_provider_is_refused_and_creates_nothing(client, world):
    world.provider.configured = False
    world.add(world.bike)
    r = world.checkout({"payment_method": "online"})
    assert r.status_code == 503 and r.json()["error"]["code"] == "payment_provider_not_configured"
    assert not world.db.tables.get("orders") and world.bike["stock_quantity"] == 5 and len(world.db.tables["cart_items"]) == 1


def test_online_checkout_reserves_stock_and_returns_client_payload(client, world):
    world.add(world.bike)
    r = world.checkout({"payment_method": "online"})
    body = r.json()
    assert r.status_code == 201 and body["order"]["status"] == "pending" and body["order"]["payment_due_at"]
    assert body["payment"]["status"] == "processing" and body["payment"]["provider"] == "testpay" and body["client_payload"]["amount"] == "1000.00"
    assert world.bike["stock_quantity"] == 4 and world.db.tables["vendor_orders"][0]["released_at"] is None      # vendor sees nothing yet


def test_provider_failure_gives_the_stock_back(client, world):
    world.provider.fail_create = True
    world.add(world.bike, 2)
    r = world.checkout({"payment_method": "online"})
    assert r.status_code == 502 and r.json()["error"]["code"] == "payment_provider_error"
    assert world.bike["stock_quantity"] == 5 and world.db.tables["orders"][0]["status"] == "cancelled"
    assert "internal" not in r.text.lower()


def test_online_disabled_by_setting(client, world):
    world.db.rows("platform_settings").append({"key": "payments.online_enabled", "value": False})
    world.add(world.bike)
    assert world.checkout({"payment_method": "online"}).json()["error"]["code"] == "online_payments_disabled"
