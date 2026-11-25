"""Step 10: coupons, announcements, reports, fulfilment overview, audit trail, commission-rule safety, extra filters and the service switch."""
import uuid

A = "/api/v1/admin"
V = "/api/v1/vendor/orders"
ALL = "2026-01-01"
TO = "2026-12-31"


def audit(world, action):
    return [a for a in world.db.tables["audit_log"] if a["action"] == action]


def coupon_body(**over):
    return {"code": "welcome10", "discount_type": "percentage", "discount_value": 10, "min_order_amount": 500, "max_discount_amount": 200, **over}


def delivered_order(client, world, qty=1):
    world.add(world.bike, qty)
    o = world.checkout().json()["order"]
    vid = [v for v in world.db.tables["vendor_orders"] if v["order_id"] == o["id"]][0]["id"]
    client.post(f"{V}/{vid}/accept", headers=world.hva)
    for st in ("preparing", "ready_for_dispatch", "delivered"):
        assert client.patch(f"{V}/{vid}/status", json={"status": st}, headers=world.hva).status_code == 200
    return o, vid


# ------------------------------------------------------------------------------------------------ RBAC
def test_every_new_admin_route_is_admin_only(client, world):
    i = str(uuid.uuid4())
    routes = [("get", f"{A}/coupons"), ("post", f"{A}/coupons"), ("get", f"{A}/coupons/{i}"), ("put", f"{A}/coupons/{i}"),
              ("get", f"{A}/announcements"), ("post", f"{A}/announcements"), ("get", f"{A}/notifications"), ("get", f"{A}/reports/orders"), ("get", f"{A}/vendor-orders"),
              ("get", f"{A}/audit-log"), ("get", f"{A}/payments/provider"), ("get", f"{A}/commission-rules/resolve"), ("patch", f"{A}/services/{i}/status")]
    for headers, expected in (({}, 401), (world.h, 403), (world.hva, 403)):
        for m, url in routes:
            kw = {"json": {}} if m in ("post", "put", "patch") else {}
            assert getattr(client, m)(url, headers=headers, **kw).status_code == expected, (m, url, expected)


# ------------------------------------------------------------------------------------------------ coupons
def test_coupon_create_validate_search_and_audit(client, world):
    r = client.post(f"{A}/coupons", json=coupon_body(), headers=world.ha)
    assert r.status_code == 201 and r.json()["code"] == "WELCOME10" and r.json()["state"] == "active" and r.json()["used_count"] == 0
    assert client.post(f"{A}/coupons", json=coupon_body(code="Welcome10"), headers=world.ha).json()["error"]["code"] == "coupon_code_taken"        # case-insensitive
    bad = [coupon_body(code="x"), coupon_body(code="has space"), coupon_body(discount_value=101), coupon_body(discount_value=0), coupon_body(discount_type="fixed"),
           coupon_body(applies_to="services"), coupon_body(valid_from="2030-01-02T00:00:00Z", valid_until="2030-01-01T00:00:00Z"), coupon_body(usage_limit=0),
           coupon_body(discount_value=-5), {**coupon_body(), "used_count": 99}]
    for body in bad:
        assert client.post(f"{A}/coupons", json=body, headers=world.ha).status_code == 422, body
    assert client.post(f"{A}/coupons", json={"code": "FLAT50", "discount_type": "fixed", "discount_value": 50}, headers=world.ha).status_code == 201
    r = client.get(f"{A}/coupons?q=welc", headers=world.ha).json()
    assert r["total"] == 1 and r["items"][0]["code"] == "WELCOME10"
    assert client.get(f"{A}/coupons?q=%25%2C)(", headers=world.ha).status_code == 200
    assert client.get(f"{A}/coupons?is_active=false", headers=world.ha).json()["total"] == 0
    assert [a["details"]["code"] for a in audit(world, "coupon_created")] == ["WELCOME10", "FLAT50"]
    assert all(a["actor_id"] == world.admin for a in audit(world, "coupon_created"))


def test_coupon_states_edit_rules_and_checkout_still_honours_them(client, world):
    cid = client.post(f"{A}/coupons", json=coupon_body(min_order_amount=0), headers=world.ha).json()["id"]
    world.add(world.bike)
    assert world.checkout({"coupon_code": "welcome10"}).status_code == 201                  # a coupon created in the console works at checkout
    row = next(c for c in world.db.tables["coupons"] if c["id"] == cid)
    row["used_count"] = 1                                                                    # the checkout SQL function increments this in production
    assert client.put(f"{A}/coupons/{cid}", json={"code": "OTHER"}, headers=world.ha).json()["error"]["code"] == "coupon_code_locked"
    assert client.put(f"{A}/coupons/{cid}", json={"usage_limit": 0}, headers=world.ha).status_code == 422
    r = client.put(f"{A}/coupons/{cid}", json={"discount_value": 15, "usage_limit": 1}, headers=world.ha)
    assert r.status_code == 200 and r.json()["discount_value"] == 15 and r.json()["state"] == "exhausted"
    assert client.put(f"{A}/coupons/{cid}", json={"discount_type": "fixed"}, headers=world.ha).status_code == 422                # max_discount_amount only for percentage
    assert client.put(f"{A}/coupons/{cid}", json={"discount_value": 150}, headers=world.ha).status_code == 422
    assert client.put(f"{A}/coupons/{cid}", json={"valid_until": "2000-01-01T00:00:00Z"}, headers=world.ha).status_code == 422       # before valid_from
    assert client.put(f"{A}/coupons/{cid}", json={}, headers=world.ha).status_code == 400
    assert client.put(f"{A}/coupons/{cid}", json={"is_active": False}, headers=world.ha).json()["state"] == "inactive"
    world.add(world.bike)
    assert world.checkout({"coupon_code": "welcome10"}).status_code == 422                  # deactivated: checkout refuses it
    assert client.put(f"{A}/coupons/{cid}", json={"valid_from": "2099-01-01T00:00:00Z", "valid_until": "2099-02-01T00:00:00Z", "is_active": True}, headers=world.ha).json()["state"] == "scheduled"
    assert client.get(f"{A}/coupons/{uuid.uuid4()}", headers=world.ha).status_code == 404
    assert client.delete(f"{A}/coupons/{cid}", headers=world.ha).status_code == 405        # no delete: orders keep what they used
    assert audit(world, "coupon_updated")


# ------------------------------------------------------------------------------------------------ announcements
def test_announcement_to_customers_creates_in_app_notifications_atomically(client, world):
    inactive = world.db.add_profile(status="inactive")
    r = client.post(f"{A}/announcements", json={"title": "Festive sale", "message": "Up to 20% off cycles.", "type": "promotion", "audience": "customers"}, headers=world.ha)
    assert r.status_code == 201, r.text
    a = r.json()
    assert a["recipient_count"] == 2 and a["delivered"] == 2 and a["read"] == 0 and a["channel"] == "in_app" and a["created_by"] == world.admin
    mine = client.get("/api/v1/notifications", headers=world.h).json()
    assert mine["unread_count"] == 1 and mine["items"][0]["title"] == "Festive sale" and mine["items"][0]["type"] == "promotion"
    assert client.get("/api/v1/notifications", headers=world.hva).json()["total"] == 0                       # vendors were not in the audience
    assert not [n for n in world.db.tables["notifications"] if n["user_id"] == inactive]                      # inactive accounts get nothing
    client.post(f"/api/v1/notifications/{mine['items'][0]['id']}/read", headers=world.h)
    h = client.get(f"{A}/announcements", headers=world.ha).json()
    assert h["total"] == 1 and h["items"][0]["read"] == 1 and h["items"][0]["delivered"] == 2
    assert audit(world, "announcement_sent")[0]["details"]["recipients"] == 2


def test_announcement_audiences_validation_and_no_recipients(client, world):
    post = lambda body: client.post(f"{A}/announcements", json={"title": "Notice", "message": "Hello everyone", **body}, headers=world.ha)  # noqa: E731
    assert post({"audience": "vendors", "type": "system"}).json()["recipient_count"] == 2
    assert client.get("/api/v1/notifications", headers=world.hva).json()["total"] == 1
    s = post({"audience": "specific", "user_ids": [world.cust]})
    assert s.status_code == 201 and s.json()["recipient_count"] == 1 and s.json()["audience"] == "specific"
    assert post({"audience": "specific", "user_ids": [world.cust, world.admin]}).json()["error"]["code"] == "invalid_recipient"      # admins are not recipients
    assert post({"audience": "specific", "user_ids": [str(uuid.uuid4())]}).json()["error"]["code"] == "invalid_recipient"
    for body in ({"audience": "specific"}, {"audience": "customers", "user_ids": [world.cust]}, {"audience": "everyone"}, {"audience": "customers", "type": "order"},
                 {"audience": "customers", "title": "no"}, {"audience": "customers", "message": ""}, {"audience": "customers", "role": "admin"}):
        assert post(body).status_code == 422, body
    world.db.profile(world.cust)["status"] = "inactive"; world.db.profile(world.other)["status"] = "inactive"
    r = post({"audience": "customers"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "no_recipients"
    assert len(client.get(f"{A}/announcements", headers=world.ha).json()["items"]) == 2                    # the failed send left no announcement behind
    assert client.get(f"{A}/announcements?audience=vendors", headers=world.ha).json()["total"] == 1


def test_admin_notification_records_include_order_updates(client, world):
    world.add(world.bike); world.checkout()
    client.post(f"{A}/announcements", json={"title": "Notice", "message": "Hello all", "audience": "customers"}, headers=world.ha)
    allr = client.get(f"{A}/notifications", headers=world.ha).json()
    assert allr["total"] >= 2 and all(n["channel"] == "in_app" for n in allr["items"]) and any(n["recipient_name"] for n in allr["items"])
    assert {n["type"] for n in client.get(f"{A}/notifications?type=announcement", headers=world.ha).json()["items"]} == {"announcement"}
    assert client.get(f"{A}/notifications?user_id={world.cust}", headers=world.ha).json()["total"] >= 1
    assert client.get(f"{A}/notifications?type=bogus", headers=world.ha).status_code == 422
    assert client.get(f"{A}/notifications?q=%25%2C(", headers=world.ha).status_code == 200


# ------------------------------------------------------------------------------------------------ reports
def test_reports_orders_sales_payments_and_period_rules(client, world):
    delivered_order(client, world, 2)
    world.add(world.pads); world.checkout()
    q = f"?from={ALL}&to={TO}"
    o = client.get(f"{A}/reports/orders{q}", headers=world.ha).json()
    assert o["kind"] == "orders" and o["timezone"] == "Asia/Kolkata" and o["data"]["total"] == 2
    assert o["data"]["by_status"] == {"completed": 1, "confirmed": 1} or sum(o["data"]["by_status"].values()) == 2
    assert o["data"]["by_payment_method"] == {"cod": 2} and o["data"]["value"] == 2250.5
    s = client.get(f"{A}/reports/sales{q}", headers=world.ha).json()["data"]
    assert s["delivered_orders"] == 1 and s["gross_sales"] == 2000 and s["commission"] == 200
    assert s["by_vendor"][0]["vendor_name"] == "Alpha" and s["by_vendor"][0]["sales"] == 2000
    assert s["by_product"][0]["product_name"] == "Bike" and s["by_product"][0]["units"] == 2
    assert sum(p["value"] for p in s["series"]) == 2000
    p = client.get(f"{A}/reports/payments{q}", headers=world.ha).json()["data"]
    assert p["total"] == 2 and p["by_method"]["cod"]["count"] == 2 and p["collected"] == 0, "uncollected COD is never counted as collected"
    v = client.get(f"{A}/reports/vendors{q}", headers=world.ha).json()["data"]
    assert v["total"] == 2 and v["performance"][0]["business_name"] == "Alpha" and v["performance"][0]["orders_delivered"] == 1
    c = client.get(f"{A}/reports/customers{q}", headers=world.ha).json()["data"]
    assert c["active_in_period"] == 1 and c["top_customers"][0]["customer_id"] == world.cust and c["top_customers"][0]["orders"] == 2
    sv = client.get(f"{A}/reports/services{q}", headers=world.ha).json()["data"]
    assert sv["total"] == 0 and sv["by_status"] == {} and sv["pickup"]["requests"] == 0                      # nothing booked: empty, not invented
    # period rules
    assert client.get(f"{A}/reports/orders?from=2026-02-01&to=2026-01-01", headers=world.ha).json()["error"]["code"] == "invalid_range"
    assert client.get(f"{A}/reports/orders?from=2020-01-01&to=2026-01-01", headers=world.ha).json()["error"]["code"] == "range_too_long"
    assert client.get(f"{A}/reports/bogus{q}", headers=world.ha).status_code == 422
    assert client.get(f"{A}/reports/orders?from=nope", headers=world.ha).status_code == 422
    empty = client.get(f"{A}/reports/orders?from=2030-01-01&to=2030-01-03", headers=world.ha).json()["data"]
    assert empty["total"] == 0 and len(empty["series"]) == 3 and all(d["count"] == 0 for d in empty["series"])
    default = client.get(f"{A}/reports/orders", headers=world.ha).json()
    assert len(default["data"]["series"]) == 30                                                              # default: last 30 local days


def test_service_report_counts_bookings_and_pickups(client, swd):
    for i in range(2):
        assert swd.book(**swd.pickup_body(slot_start=f"1{i}:00")).status_code == 201
    swd.book(service=swd.svc_b)
    data = client.get(f"{A}/reports/services?from={ALL}&to={TO}", headers=swd.ha).json()["data"]
    assert data["total"] == 3 and data["by_status"] == {"pending": 3} and data["pickup"]["bookings_needing_pickup"] == 2 and data["pickup"]["requests"] == 2
    assert data["pickup"]["pickup_by_status"] == {"pending": 2} and {v["vendor_name"] for v in data["by_vendor"]} == {"Alpha Cycles", "Beta Bikes"}
    assert data["by_category"][0] == {"category_name": "General Servicing", "total": 3}


# ------------------------------------------------------------------------------------------------ fulfilment overview
def test_fulfilment_overview_lists_released_vendor_orders_with_filters(client, world):
    delivered_order(client, world)
    world.add(world.pads); world.checkout()
    world.add(world.bike); world.checkout({"payment_method": "online"})                    # unpaid online order: not released to the vendor, so not fulfilment yet
    r = client.get(f"{A}/vendor-orders", headers=world.ha).json()
    assert r["total"] == 2 and {i["status"] for i in r["items"]} == {"delivered", "pending"}
    d = next(i for i in r["items"] if i["status"] == "delivered")
    assert d["vendor_name"] == "Alpha" and d["customer_name"] and d["delivery_city"] == "Pune" and d["item_count"] == 1 and d["payment_method"] == "cod" and d["delivered_at"]
    assert client.get(f"{A}/vendor-orders?status=pending", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/vendor-orders?vendor_id={world.vb['id']}", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/vendor-orders?q={d['order_number']}", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/vendor-orders?q=Beta", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/vendor-orders?q=%25%2C)(", headers=world.ha).status_code == 200
    assert client.get(f"{A}/vendor-orders?status=bogus", headers=world.ha).status_code == 422


# ------------------------------------------------------------------------------------------------ order / payment / refund / settlement filters
def test_order_filters_date_sort_customer_and_vendor_search(client, world):
    world.add(world.bike); world.checkout()
    world.add(world.pads); world.checkout()
    ids = lambda q: [o["order_number"] for o in client.get(f"{A}/orders{q}", headers=world.ha).json()["items"]]  # noqa: E731
    nums = [o["order_number"] for o in world.db.tables["orders"]]
    assert len(ids("")) == 2 and ids("?sort=oldest")[0] == nums[0] and ids("?sort=amount_high")[0] == nums[0]
    assert ids("?sort=amount_low")[0] == nums[1] and client.get(f"{A}/orders?sort=bogus", headers=world.ha).status_code == 422
    world.db.profile(world.cust)["full_name"] = "Anjali Verma"
    assert len(ids("?q=anjali")) == 2 and ids("?q=nobody") == []
    assert len(ids("?q=Beta")) == 1 and len(ids("?q=Alpha")) == 1                                            # seller business names
    assert len(ids(f"?q={world.db.profile(world.cust)['email']}")) == 2
    assert len(ids("?date_from=2026-01-01&date_to=2026-01-01")) == 2 and ids("?date_from=2026-01-02") == [] and ids("?date_to=2025-12-31") == []


def test_payment_list_search_dates_and_enrichment(client, world):
    world.add(world.bike); world.checkout()
    world.add(world.pads)
    world.checkout({"payment_method": "online"})
    pay = world.db.tables["payments"][-1]
    pay["provider_order_id"] = "po_ABC123"
    r = client.get(f"{A}/payments", headers=world.ha).json()
    assert r["total"] == 2 and all(i["order_number"] and i["customer_name"] for i in r["items"])
    assert client.get(f"{A}/payments?q=ABC123", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/payments?q={world.db.tables['orders'][0]['order_number']}", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/payments?q=nothing-here", headers=world.ha).json()["total"] == 0
    assert client.get(f"{A}/payments?date_from=2026-01-01&date_to=2026-01-01", headers=world.ha).json()["total"] == 2
    assert client.get(f"{A}/payments?date_from=2026-01-02", headers=world.ha).json()["total"] == 0
    d = client.get(f"{A}/payments/{pay['id']}", headers=world.ha).json()
    assert d["order_number"] and d["customer_name"] and "client_secret" not in str(d) and "key_secret" not in str(d)


def test_payment_provider_info_never_returns_credentials(client, world, provider):
    r = client.get(f"{A}/payments/provider", headers=world.ha).json()
    assert set(r) == {"configured", "provider", "refunds_via_provider"} and r["configured"] is True
    provider.configured = False
    r = client.get(f"{A}/payments/provider", headers=world.ha).json()
    assert r == {"configured": False, "provider": None, "refunds_via_provider": False}


def test_refund_list_enrichment_search_and_settlement_filters(client, world):
    o, vid = delivered_order(client, world, 2)
    world.add(world.bike); world.checkout({"payment_method": "online"})
    pay = world.db.tables["payments"][-1]
    world.webhook({"id": "e1", "type": "payment.succeeded", "order": pay["provider_order_id"], "payment": "pay_1", "amount": str(pay["amount"]), "currency": "INR"})
    rf = client.post(f"{A}/refunds", json={"payment_id": pay["id"], "amount": 100, "reason": "Damaged item"}, headers={**world.ha, "Idempotency-Key": "refund-key-0001"})
    assert rf.status_code == 201, rf.text
    r = client.get(f"{A}/refunds", headers=world.ha).json()
    assert r["total"] == 1 and r["items"][0]["order_number"]
    assert client.get(f"{A}/refunds?q=damaged", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/refunds?q={r['items'][0]['order_number']}", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/refunds?q=zzz", headers=world.ha).json()["total"] == 0
    assert client.get(f"{A}/refunds?date_from=2026-01-02", headers=world.ha).json()["total"] == 0
    assert client.get(f"{A}/refunds/{r['items'][0]['id']}", headers=world.ha).json()["order_number"]
    s = client.get(f"{A}/settlements", headers=world.ha).json()
    assert s["items"][0]["vendor_name"] == "Alpha" and s["total"] == 1
    assert client.get(f"{A}/settlements?date_from=2026-01-01&date_to=2026-01-01", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/settlements?date_from=2026-02-01", headers=world.ha).json()["total"] == 0


# ------------------------------------------------------------------------------------------------ commission rules
def test_commission_rules_show_scope_names_and_refuse_ambiguous_rules(client, world):
    rules = client.get(f"{A}/commission-rules", headers=world.ha).json()
    assert rules[0]["scope"] == "global" and rules[0]["state"] == "active"
    base = {"name": "Alpha special", "applies_to": "product", "vendor_id": world.va["id"], "commission_type": "percentage", "commission_value": 5, "priority": 1}
    r = client.post(f"{A}/commission-rules", json=base, headers=world.ha)
    assert r.status_code == 201 and r.json()["scope"] == "vendor" and r.json()["vendor_name"] == "Alpha"
    dup = client.post(f"{A}/commission-rules", json={**base, "name": "Alpha duplicate"}, headers=world.ha)
    assert dup.status_code == 409 and dup.json()["error"]["code"] == "commission_rule_conflict"
    ok = client.post(f"{A}/commission-rules", json={**base, "name": "Alpha higher", "priority": 2}, headers=world.ha)
    assert ok.status_code == 201
    # a deactivated twin may exist; re-activating it would recreate the conflict
    off = client.post(f"{A}/commission-rules", json={**base, "name": "Alpha off", "priority": 2, "is_active": False}, headers=world.ha).json()
    assert client.put(f"{A}/commission-rules/{off['id']}", json={"is_active": True}, headers=world.ha).json()["error"]["code"] == "commission_rule_conflict"
    cat_rule = client.post(f"{A}/commission-rules", json={"name": "Cycles", "applies_to": "product", "category_id": world.cat["id"], "commission_value": 7}, headers=world.ha).json()
    assert cat_rule["scope"] == "category" and cat_rule["category_name"] == "Cycles"
    assert client.put(f"{A}/commission-rules/{cat_rule['id']}", json={"commission_value": 8}, headers=world.ha).json()["commission_value"] == 8
    assert client.put(f"{A}/commission-rules/{cat_rule['id']}", json={"commission_value": 120}, headers=world.ha).status_code == 422
    # which rule applies
    res = client.get(f"{A}/commission-rules/resolve?vendor_id={world.va['id']}&category_id={world.cat['id']}", headers=world.ha).json()
    assert res["rule"]["name"] == "Alpha higher"                                                             # vendor-specific beats category-specific, higher priority wins
    res = client.get(f"{A}/commission-rules/resolve?vendor_id={world.vb['id']}&category_id={world.parts['id']}", headers=world.ha).json()
    assert res["rule"]["name"] == "Global"
    world.db.tables["commission_rules"][0]["is_active"] = False
    none = client.get(f"{A}/commission-rules/resolve?vendor_id={world.vb['id']}&category_id={world.parts['id']}", headers=world.ha).json()
    assert none["rule"] is None and "missing_rule_policy" in none["note"]
    assert len(audit(world, "commission_rule_created")) == 4 and audit(world, "commission_rule_updated")


def test_changing_a_rule_does_not_rewrite_recorded_order_commission(client, world):
    o, vid = delivered_order(client, world, 2)
    before = next(v for v in world.db.tables["vendor_orders"] if v["id"] == vid)["commission_amount"]
    rid = world.db.tables["commission_rules"][0]["id"]
    assert client.put(f"{A}/commission-rules/{rid}", json={"commission_value": 50}, headers=world.ha).status_code == 200
    assert next(v for v in world.db.tables["vendor_orders"] if v["id"] == vid)["commission_amount"] == before == 200
    assert client.get(f"{A}/settlements", headers=world.ha).json()["items"][0]["commission_amount"] == 200


# ------------------------------------------------------------------------------------------------ products
def test_admin_product_sort_stock_filter_and_audit_trail(client, world):
    world.pads["stock_quantity"] = 0
    r = client.get(f"{A}/products?in_stock=false", headers=world.ha).json()
    assert [p["id"] for p in r["items"]] == [world.pads["id"]]
    assert [p["id"] for p in client.get(f"{A}/products?in_stock=true", headers=world.ha).json()["items"]] == [world.bike["id"]]
    assert client.get(f"{A}/products?sort=price_high_to_low", headers=world.ha).json()["items"][0]["id"] == world.bike["id"]
    assert client.get(f"{A}/products?sort=name", headers=world.ha).json()["items"][0]["name"] == "Bike"
    assert client.get(f"{A}/products?sort=bogus", headers=world.ha).status_code == 422
    pid = world.bike["id"]
    assert client.patch(f"{A}/products/{pid}/approval", json={"approval_status": "rejected"}, headers=world.ha).status_code == 422
    assert client.patch(f"{A}/products/{pid}/approval", json={"approval_status": "rejected", "review_notes": "Photos are unclear"}, headers=world.ha).status_code == 200
    assert client.patch(f"{A}/products/{pid}/approval", json={"approval_status": "approved"}, headers=world.ha).status_code == 200
    assert client.patch(f"{A}/products/{pid}/featured", json={"is_featured": True}, headers=world.ha).status_code == 200
    assert client.patch(f"{A}/products/{pid}/status", json={"is_active": False}, headers=world.ha).status_code == 200
    actions = [a["action"] for a in world.db.tables["audit_log"] if a["entity_type"] == "product"]
    assert actions == ["product_approval_changed", "product_approval_changed", "product_featured", "product_deactivated"]
    assert world.db.tables["audit_log"][0]["details"]["review_notes"] == "Photos are unclear" and world.db.tables["audit_log"][0]["actor_id"] == world.admin
    trail = client.get(f"{A}/audit-log?entity_type=product&entity_id={pid}", headers=world.ha).json()
    assert trail["total"] == 4 and trail["items"][0]["action"] == "product_deactivated" and trail["items"][0]["actor_id"] == world.admin
    # a vendor can never moderate their own listing
    assert client.patch(f"{A}/products/{pid}/approval", json={"approval_status": "approved"}, headers=world.hva).status_code == 403


def test_audit_log_filters_and_validation(client, world):
    client.post(f"{A}/coupons", json=coupon_body(), headers=world.ha)
    client.put(f"{A}/settings/payments.cod_enabled", json={"value": False}, headers=world.ha)
    r = client.get(f"{A}/audit-log", headers=world.ha).json()
    assert r["total"] == 2 and {i["action"] for i in r["items"]} == {"coupon_created", "setting_changed"} and r["items"][0]["actor_role"] == "admin"
    assert client.get(f"{A}/audit-log?action=setting_changed", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/audit-log?entity_type=BAD;DROP", headers=world.ha).status_code == 422


# ------------------------------------------------------------------------------------------------ services
def test_admin_can_deactivate_a_service_with_a_reason_and_the_vendor_is_told(client, swd):
    url = f"{A}/services/{swd.svc['id']}/status"
    assert client.patch(url, json={"is_active": False}, headers=swd.ha).status_code == 422                # reason required
    assert client.patch(url, json={"is_active": False, "reason": "ab"}, headers=swd.ha).status_code == 422
    r = client.patch(url, json={"is_active": False, "reason": "Misleading price"}, headers=swd.ha)
    assert r.status_code == 200 and r.json()["is_active"] is False and r.json()["vendor_name"] == "Alpha Cycles"
    assert client.patch(url, json={"is_active": False, "reason": "again please"}, headers=swd.ha).json()["error"]["code"] == "no_change"
    note = [n for n in swd.db.tables["notifications"] if n["user_id"] == swd.ua][-1]
    assert "Misleading price" in note["message"] and note["related_type"] == "vendor_service"
    assert [s["id"] for s in client.get("/api/v1/services", headers=swd.h).json()["items"]] == [swd.svc_b["id"]], "customers no longer see it"
    assert audit_of(swd, "service_deactivated")[0]["details"]["reason"] == "Misleading price"
    assert client.patch(url, json={"is_active": True}, headers=swd.ha).json()["is_active"] is True
    assert client.patch(f"{A}/services/{uuid.uuid4()}/status", json={"is_active": True}, headers=swd.ha).status_code == 404
    assert client.patch(url, json={"is_active": False, "reason": "x" * 20, "vendor_id": swd.vb["id"]}, headers=swd.ha).status_code == 422
    assert client.patch(url, json={"is_active": False, "reason": "Not allowed"}, headers=swd.hva).status_code == 403


def audit_of(w, action):
    return [a for a in w.db.tables["audit_log"] if a["action"] == action]


def test_service_availability_filter_and_booking_pickup_search(client, swd):
    swd.svc_b["is_available"] = False
    ids = lambda q: [s["id"] for s in client.get(f"{A}/services{q}", headers=swd.ha).json()["items"]]  # noqa: E731
    assert ids("?is_available=false") == [swd.svc_b["id"]] and ids("?is_available=true") == [swd.svc["id"]]
    swd.db.profile(swd.cust)["full_name"] = "Rohan Mehta"
    a = swd.book(**swd.pickup_body()).json()
    swd.svc_b["is_available"] = True
    swd.book(service=swd.svc_b, headers=swd.hother)
    bk = lambda q: [b["id"] for b in client.get(f"{A}/service-bookings{q}", headers=swd.ha).json()["items"]]  # noqa: E731
    assert bk("?q=rohan") == [a["id"]] and bk("?q=Beta") != [] and len(bk("?q=Beta")) == 1 and bk("?q=Alpha") == [a["id"]] and bk("?q=nobody") == []
    assert client.get(f"{A}/service-bookings", headers=swd.ha).json()["items"][0]["service_category"] == "General Servicing"
    assert bk(f"?q={a['booking_number']}") == [a["id"]] and bk("?q=%25%2C)(") == []
    pk = lambda q: client.get(f"{A}/pickup-requests{q}", headers=swd.ha).json()
    assert pk("")["total"] == 1 and pk("?q=rohan")["total"] == 1 and pk("?q=nobody")["total"] == 0 and pk(f"?q={a['booking_number']}")["total"] == 1


# ------------------------------------------------------------------------------------------------ timelines
def test_admin_order_timeline_names_who_changed_what(client, world):
    o, vid = delivered_order(client, world)
    # the in-memory SQL twin does not write order history (the real functions do); seed what they would have recorded
    for frm, to, who in ((None, "pending", world.cust), ("pending", "accepted", world.ua), ("ready_for_dispatch", "delivered", world.ua)):
        world.db.rows("order_status_history").append(world.db.apply_defaults("order_status_history", {"order_id": o["id"], "vendor_order_id": vid, "from_status": frm, "to_status": to, "changed_by": who, "note": None}))
    r = client.get(f"{A}/orders/{o['id']}/timeline", headers=world.ha)
    assert r.status_code == 200
    events = r.json()
    steps = [(e["scope"], e["to_status"]) for e in events]
    assert ("vendor_order", "accepted") in steps and ("vendor_order", "delivered") in steps
    done = next(e for e in events if e["to_status"] == "delivered")
    assert done["vendor_name"] == "Alpha" and done["changed_by_name"] and done["changed_by_role"] == "vendor"
    assert client.get(f"{A}/orders/{uuid.uuid4()}/timeline", headers=world.ha).status_code == 404
    assert client.get(f"{A}/orders/{o['id']}/timeline", headers=world.h).status_code == 403
    assert client.get(f"{A}/orders/{o['id']}/timeline").status_code == 401


def test_admin_booking_timeline(client, swd):
    b = swd.book().json()
    client.post(f"/api/v1/vendor/service-bookings/{b['id']}/accept", headers=swd.hva)
    events = client.get(f"{A}/service-bookings/{b['id']}/timeline", headers=swd.ha).json()
    assert [e["to_status"] for e in events][-1] == "accepted" and all(e["scope"] == "booking" for e in events)
    assert client.get(f"{A}/service-bookings/{uuid.uuid4()}/timeline", headers=swd.ha).status_code == 404
    assert client.get(f"{A}/service-bookings/{b['id']}/timeline", headers=swd.hva).status_code == 403


# ------------------------------------------------------------------------------------------------ no duplicate categories
def test_product_and_service_category_names_are_unique(client, world, swd):
    r = client.post(f"{A}/categories", json={"name": "Child Seats", "kind": "accessory"}, headers=world.ha)
    assert r.status_code == 201
    dup = client.post(f"{A}/categories", json={"name": "  child seats ", "kind": "accessory"}, headers=world.ha)
    assert dup.status_code == 409 and dup.json()["error"]["code"] == "category_name_taken"
    assert client.post(f"{A}/categories", json={"name": "Child Seats", "kind": "spare_part"}, headers=world.ha).status_code == 201       # same name in another type is a different category
    other = client.post(f"{A}/categories", json={"name": "Baskets", "kind": "accessory"}, headers=world.ha).json()
    assert client.put(f"{A}/categories/{other['id']}", json={"name": "CHILD SEATS"}, headers=world.ha).json()["error"]["code"] == "category_name_taken"
    assert client.put(f"{A}/categories/{other['id']}", json={"name": "Baskets", "description": "ok"}, headers=world.ha).status_code == 200      # keeping its own name is fine
    assert client.put(f"{A}/categories/{r.json()['id']}", json={"name": "Child seats"}, headers=world.ha).status_code == 200                     # re-casing itself is fine


def test_service_category_names_are_unique(client, swd):
    dup = client.post(f"{A}/service-categories", json={"name": "general servicing"}, headers=swd.ha)
    assert dup.status_code == 409 and dup.json()["error"]["code"] == "category_name_taken"
    new = client.post(f"{A}/service-categories", json={"name": "Wheel Truing"}, headers=swd.ha).json()
    assert client.put(f"{A}/service-categories/{new['id']}", json={"name": "Puncture Repair"}, headers=swd.ha).json()["error"]["code"] == "category_name_taken"
    assert client.put(f"{A}/service-categories/{new['id']}", json={"name": "Wheel Truing", "description": "ok"}, headers=swd.ha).status_code == 200
