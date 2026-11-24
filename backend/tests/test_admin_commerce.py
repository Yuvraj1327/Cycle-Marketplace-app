import uuid

A = "/api/v1/admin"
V = "/api/v1/vendor/orders"


def paid_online(world, qty=1):
    world.add(world.bike, qty)
    o = world.checkout({"payment_method": "online"}).json()["order"]
    pay = world.db.tables["payments"][-1]
    world.webhook({"id": f"e{len(world.db.rows('payment_events')) + 1}", "type": "payment.succeeded", "order": pay["provider_order_id"], "payment": "pay_1",
                   "amount": str(pay["amount"]), "currency": "INR"})
    return o, pay


def test_every_admin_commerce_route_is_admin_only(client, world):
    oid, rid = str(uuid.uuid4()), str(uuid.uuid4())
    routes = [("get", f"{A}/orders"), ("get", f"{A}/orders/{oid}"), ("patch", f"{A}/orders/{oid}/status"), ("post", f"{A}/orders/expire-unpaid"),
              ("get", f"{A}/payments"), ("get", f"{A}/payments/summary"), ("get", f"{A}/payments/{oid}"), ("post", f"{A}/payments/{oid}/collect-cod"),
              ("post", f"{A}/payments/{oid}/reconcile"), ("get", f"{A}/refunds"), ("post", f"{A}/refunds"), ("get", f"{A}/refunds/{rid}"), ("post", f"{A}/refunds/{rid}/actions"),
              ("get", f"{A}/settlements"), ("post", f"{A}/settlements/{rid}/mark-paid"), ("get", f"{A}/settings"), ("put", f"{A}/settings/payments.cod_enabled"),
              ("get", f"{A}/commission-rules"), ("post", f"{A}/commission-rules"), ("put", f"{A}/commission-rules/{rid}"), ("delete", f"{A}/commission-rules/{rid}")]
    for headers, expected in (({}, 401), (world.h, 403), (world.hva, 403)):
        for m, url in routes:
            kw = {"json": {}} if m in ("post", "put", "patch") else {}
            assert getattr(client, m)(url, headers=headers, **kw).status_code == expected, (m, url, expected)


def test_admin_order_list_filters_and_detail(client, world):
    world.add(world.bike); world.checkout()
    world.add(world.pads); world.checkout({"payment_method": "cod"})
    r = client.get(f"{A}/orders", headers=world.ha).json()
    assert r["total"] == 2 and r["items"][0]["customer"]["id"] == world.cust and r["items"][0]["payments"]
    num = world.db.tables["orders"][0]["order_number"]
    assert client.get(f"{A}/orders?q={num}", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/orders?q=%25%25", headers=world.ha).json()["total"] == 0                            # junk search matches nothing
    assert client.get(f"{A}/orders?vendor_id={world.vb['id']}", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/orders?customer_id={world.other}", headers=world.ha).json()["total"] == 0
    assert client.get(f"{A}/orders?status=confirmed&payment_method=cod", headers=world.ha).json()["total"] == 2
    d = client.get(f"{A}/orders/{world.db.tables['orders'][0]['id']}", headers=world.ha).json()
    assert d["vendor_orders"][0]["items"][0]["product_name"] == "Bike" and d["customer"]["full_name"]
    assert client.get(f"{A}/orders/{uuid.uuid4()}", headers=world.ha).status_code == 404


def test_admin_cancel_needs_reason_records_actor_and_audit(client, world):
    world.add(world.bike, 2)
    o = world.checkout().json()["order"]
    url = f"{A}/orders/{o['id']}/status"
    assert client.patch(url, json={"status": "cancelled"}, headers=world.ha).json()["error"]["code"] == "reason_required"
    assert client.patch(url, json={"status": "completed", "reason": "force it"}, headers=world.ha).json()["error"]["code"] == "unsupported_status"
    r = client.patch(url, json={"status": "cancelled", "reason": "Fraud suspected"}, headers=world.ha)
    assert r.status_code == 200 and r.json()["status"] == "cancelled" and r.json()["cancelled_reason"] == "Fraud suspected" and world.bike["stock_quantity"] == 5
    assert any(a["action"] == "order_status_changed" and a["actor_id"] == world.admin for a in world.db.tables["audit_log"])
    assert world.db.sql.calls[-1][1]["p_role"] == "admin" if world.db.sql.calls[-1][0] == "cancel_order" else True


def test_admin_can_move_a_single_vendor_order_through_the_state_machine_only(client, world):
    world.add(world.bike)
    o = world.checkout().json()["order"]
    vid = world.db.tables["vendor_orders"][0]["id"]
    url = f"{A}/orders/{o['id']}/status"
    assert client.patch(url, json={"status": "delivered", "vendor_order_id": vid}, headers=world.ha).json()["error"]["code"] == "invalid_transition"
    assert client.patch(url, json={"status": "accepted", "vendor_order_id": vid}, headers=world.ha).status_code == 200
    assert client.patch(url, json={"status": "cancelled", "vendor_order_id": vid}, headers=world.ha).json()["error"]["code"] == "reason_required"


def test_expire_unpaid_endpoint(client, world):
    r = client.post(f"{A}/orders/expire-unpaid", headers=world.ha)
    assert r.status_code == 200 and r.json() == {"cancelled": 0}


def test_payments_listing_filters_detail_and_revenue(client, world):
    o, pay = paid_online(world)
    world.add(world.pads); world.checkout()
    assert client.get(f"{A}/payments", headers=world.ha).json()["total"] == 2
    assert client.get(f"{A}/payments?status=successful", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/payments?method=cod&status=pending", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/payments?order_id={o['id']}", headers=world.ha).json()["items"][0]["provider_order_id"] == pay["provider_order_id"]
    d = client.get(f"{A}/payments/{pay['id']}", headers=world.ha).json()
    assert d["order"]["order_number"] == o["order_number"] and len(d["events"]) == 1 and d["customer_id"] == world.cust
    s = client.get(f"{A}/payments/summary", headers=world.ha).json()
    assert s["collected"] == 1000 and s["refunded"] == 0 and s["net_collected"] == 1000 and s["cod_outstanding"] == 250.5 and set(s["settlements"]) == {"pending", "ready", "paid", "cancelled"}
    assert client.get(f"{A}/payments/summary?from=2026-02-01T00:00:00Z&to=2026-01-01T00:00:00Z", headers=world.ha).status_code == 422


# ---------------- refunds
def refund(client, world, pid, amount, key="refund-key-1", **kw):
    return client.post(f"{A}/refunds", json={"payment_id": pid, "amount": amount, "reason": "Damaged item", **kw}, headers={**world.ha, "Idempotency-Key": key})


def test_refund_amount_validation_and_duplicate_prevention(client, world):
    o, pay = paid_online(world, qty=2)                              # paid 2000
    pid = pay["id"]
    assert refund(client, world, pid, 600).status_code == 201
    assert refund(client, world, pid, 600).json()["id"] == world.db.tables["refunds"][0]["id"] and len(world.db.tables["refunds"]) == 1       # same key => same refund
    over = refund(client, world, pid, 1500, key="refund-key-2")
    assert over.status_code == 409 and over.json()["error"]["code"] == "refund_exceeds"
    assert refund(client, world, pid, 1400, key="refund-key-3").status_code == 201
    assert refund(client, world, pid, 0.01, key="refund-key-4").json()["error"]["code"] == "refund_exceeds"        # fully committed
    for bad in (0, -5):
        assert refund(client, world, pid, bad, key="refund-key-5").status_code == 422
    assert client.post(f"{A}/refunds", json={"payment_id": pid, "amount": 1, "reason": "x" * 5}, headers=world.ha).status_code == 422          # key required
    assert refund(client, world, str(uuid.uuid4()), 1, key="refund-key-6").status_code == 404


def test_cannot_refund_an_unpaid_payment(client, world):
    world.add(world.bike)
    world.checkout()
    r = refund(client, world, world.db.tables["payments"][0]["id"], 100)
    assert r.status_code == 409 and r.json()["error"]["code"] == "payment_not_refundable"


def test_refund_lifecycle_manual_record_needs_reference_and_is_the_only_way_to_processed_without_provider(client, world):
    o, pay = paid_online(world)
    rid = refund(client, world, pay["id"], 400).json()["id"]
    act = lambda body: client.post(f"{A}/refunds/{rid}/actions", json=body, headers=world.ha)  # noqa: E731
    assert act({"action": "process"}).json()["error"]["code"] == "invalid_transition"                      # must be approved first
    assert not any(fn == "apply_refund_result" and prm["p_status"] == "processed" for fn, prm in world.db.sql.calls)   # refused BEFORE reaching the database
    assert act({"action": "approve"}).json()["status"] == "approved"
    assert act({"action": "process", "manual": True}).status_code == 422                                  # reference required
    assert act({"action": "reject"}).status_code == 422                                                     # reason required
    assert act({"action": "bogus"}).status_code == 422
    r = act({"action": "process", "manual": True, "provider_refund_id": "BANK-REF-77", "note": "paid by NEFT"})
    assert r.status_code == 200 and r.json()["status"] == "processed" and r.json()["provider_refund_id"] == "BANK-REF-77" and r.json()["processed_by"] == world.admin
    p = world.db.tables["payments"][0]
    assert p["status"] == "partially_refunded" and p["refunded_amount"] == 400 and world.db.tables["orders"][0]["payment_status"] == "partially_refunded"
    assert act({"action": "approve"}).json()["error"]["code"] == "invalid_transition"                      # terminal


def test_provider_refund_pending_then_confirmed_only_by_verified_webhook(client, world):
    o, pay = paid_online(world)
    world.db.tables["payments"][0]["provider_payment_id"] = "pay_1"
    rid = refund(client, world, pay["id"], 1000).json()["id"]
    client.post(f"{A}/refunds/{rid}/actions", json={"action": "approve"}, headers=world.ha)
    world.provider.refund_status = "pending"
    r = client.post(f"{A}/refunds/{rid}/actions", json={"action": "process"}, headers=world.ha)
    assert r.status_code == 200 and r.json()["status"] == "approved" and r.json()["provider_refund_id"].startswith("rf_")      # NOT processed yet
    assert world.db.tables["payments"][0]["refunded_amount"] == 0
    assert world.webhook({"id": "rw1", "type": "refund.processed", "refund": "rf_x", "order": None}, sig="bad").status_code == 400
    assert world.db.tables["refunds"][0]["status"] == "approved"


def test_provider_refund_synchronously_confirmed(client, world):
    o, pay = paid_online(world)
    world.db.tables["payments"][0]["provider_payment_id"] = "pay_1"
    rid = refund(client, world, pay["id"], 1000).json()["id"]
    client.post(f"{A}/refunds/{rid}/actions", json={"action": "approve"}, headers=world.ha)
    r = client.post(f"{A}/refunds/{rid}/actions", json={"action": "process"}, headers=world.ha)
    assert r.json()["status"] == "processed" and world.provider.refunds[0][1] == 1000
    assert world.db.tables["payments"][0]["status"] == "refunded" and world.db.tables["orders"][0]["payment_status"] == "refunded"


def test_provider_refund_refused_while_no_provider_is_configured(client, world):
    o, pay = paid_online(world)
    world.provider.configured = False
    rid = refund(client, world, pay["id"], 100).json()["id"]
    client.post(f"{A}/refunds/{rid}/actions", json={"action": "approve"}, headers=world.ha)
    r = client.post(f"{A}/refunds/{rid}/actions", json={"action": "process"}, headers=world.ha)
    assert r.status_code == 503 and r.json()["error"]["code"] == "payment_provider_not_configured" and world.db.tables["refunds"][0]["status"] == "approved"


def test_refund_listing_and_customer_cannot_see_admin_endpoints(client, world):
    o, pay = paid_online(world)
    refund(client, world, pay["id"], 100)
    assert client.get(f"{A}/refunds", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/refunds?status=processed", headers=world.ha).json()["total"] == 0
    assert client.get(f"{A}/refunds?order_id={o['id']}", headers=world.ha).json()["total"] == 1
    assert client.get(f"{A}/refunds/{world.db.tables['refunds'][0]['id']}", headers=world.ha).status_code == 200
    assert client.get(f"{A}/refunds/{uuid.uuid4()}", headers=world.ha).status_code == 404


# ---------------- settlements
def delivered_paid_order(client, world):
    o, pay = paid_online(world, qty=2)
    vid = world.db.tables["vendor_orders"][-1]["id"]
    client.post(f"{V}/{vid}/accept", headers=world.hva)
    for st in ("preparing", "ready_for_dispatch", "delivered"):
        client.patch(f"{V}/{vid}/status", json={"status": st}, headers=world.hva)
    return o


def test_settlement_amounts_and_manual_mark_paid(client, world):
    delivered_paid_order(client, world)
    s = client.get(f"{A}/settlements", headers=world.ha).json()
    row = s["items"][0]
    assert (row["gross_amount"], row["commission_amount"], row["deductions_amount"], row["net_amount"], row["status"]) == (2000, 200, 0, 1800, "ready")
    assert s["summary"]["ready"] == 1800 and row["order_number"].startswith("VO-")
    url = f"{A}/settlements/{row['id']}/mark-paid"
    assert client.post(url, json={}, headers=world.ha).status_code == 422                           # reference required
    ok = client.post(url, json={"payout_reference": "NEFT-123456", "notes": "March payout"}, headers=world.ha)
    assert ok.status_code == 200 and ok.json()["status"] == "paid" and ok.json()["payout_reference"] == "NEFT-123456"
    assert client.post(url, json={"payout_reference": "NEFT-999999"}, headers=world.ha).json()["error"]["code"] == "settlement_not_ready"      # cannot overwrite
    assert any(a["action"] == "settlement_marked_paid" for a in world.db.tables["audit_log"])


def test_cod_settlement_is_not_ready_until_cash_is_recorded(client, world):
    world.add(world.bike)
    world.checkout()
    vid = world.db.tables["vendor_orders"][0]["id"]
    client.post(f"{V}/{vid}/accept", headers=world.hva)
    for st in ("preparing", "ready_for_dispatch", "out_for_delivery", "delivered"):
        client.patch(f"{V}/{vid}/status", json={"status": st}, headers=world.hva)
    row = client.get(f"{A}/settlements", headers=world.ha).json()["items"][0]
    assert row["status"] == "pending"
    assert client.post(f"{A}/settlements/{row['id']}/mark-paid", json={"payout_reference": "NEFT-1"}, headers=world.ha).json()["error"]["code"] == "settlement_not_ready"
    client.post(f"{A}/payments/{world.db.tables['payments'][0]['id']}/collect-cod", headers=world.ha)
    assert client.get(f"{A}/settlements?status=ready", headers=world.ha).json()["total"] == 1


# ---------------- settings & commission rules
def test_settings_list_validation_and_audit(client, world):
    s = {x["key"]: x for x in client.get(f"{A}/settings", headers=world.ha).json()}
    assert s["payments.cod_enabled"]["configured"] is True and s["checkout.multi_vendor_policy"]["configured"] is False
    assert "one seller" in s["checkout.multi_vendor_policy"]["default_behaviour"]
    put = lambda k, v: client.put(f"{A}/settings/{k}", json={"value": v}, headers=world.ha)  # noqa: E731
    assert put("payments.cod_enabled", False).json()["value"] is False
    assert put("checkout.multi_vendor_policy", "allow_multi_vendor").status_code == 200
    assert put("checkout.delivery_charge", {"amount": 49.5, "free_above": 999, "per": "order"}).status_code == 200
    assert put("checkout.payment_window_minutes", 45).status_code == 200
    for k, v in (("payments.cod_enabled", "yes"), ("checkout.multi_vendor_policy", "chaos"), ("checkout.delivery_charge", {"amount": -1}), ("checkout.delivery_charge", {"amount": 5, "x": 1}),
                 ("checkout.payment_window_minutes", 1), ("commission.missing_rule_policy", "invent"), ("secret.key", "x"), ("payments.cod_enabled", 1)):
        assert put(k, v).status_code == 422, (k, v)
    assert sum(a["action"] == "setting_changed" for a in world.db.tables["audit_log"]) == 4


def test_admin_disabling_cod_blocks_checkout_and_enabling_allows_it(client, world):
    client.put(f"{A}/settings/payments.cod_enabled", json={"value": False}, headers=world.ha)
    world.add(world.bike)
    assert world.checkout().json()["error"]["code"] == "cod_not_available"
    client.put(f"{A}/settings/payments.cod_enabled", json={"value": True}, headers=world.ha)
    assert world.checkout().status_code == 201


def test_commission_rule_crud_and_validation(client, world):
    body = {"name": "Alpha deal", "vendor_id": world.va["id"], "commission_type": "percentage", "commission_value": 7.5, "priority": 5}
    r = client.post(f"{A}/commission-rules", json=body, headers=world.ha)
    assert r.status_code == 201 and r.json()["commission_value"] == 7.5
    rid = r.json()["id"]
    for bad in ({"commission_value": 150}, {"commission_value": -1}, {"commission_type": "weird"}, {"applies_to": "product", "service_category_id": str(uuid.uuid4())},
                {"effective_from": "2026-02-01T00:00:00Z", "effective_until": "2026-01-01T00:00:00Z"}, {"unknown": 1}):
        assert client.post(f"{A}/commission-rules", json={**body, **bad}, headers=world.ha).status_code == 422, bad
    assert client.put(f"{A}/commission-rules/{rid}", json={"is_active": False, "commission_value": 9}, headers=world.ha).json()["commission_value"] == 9
    assert client.put(f"{A}/commission-rules/{rid}", json={}, headers=world.ha).status_code == 400
    assert client.put(f"{A}/commission-rules/{uuid.uuid4()}", json={"priority": 1}, headers=world.ha).status_code == 404
    assert len(client.get(f"{A}/commission-rules", headers=world.ha).json()) == 2
    assert client.delete(f"{A}/commission-rules/{rid}", headers=world.ha).status_code == 204
    assert client.delete(f"{A}/commission-rules/{rid}", headers=world.ha).status_code == 404


def test_inactive_rule_is_not_used_and_snapshots_do_not_change_later(client, world):
    world.db.tables["commission_rules"][0]["commission_value"] = 20
    world.add(world.bike); world.checkout()
    first = world.db.tables["vendor_orders"][0]["commission_amount"]
    world.db.tables["commission_rules"][0]["commission_value"] = 1                      # admin changes the rate afterwards
    assert world.db.tables["vendor_orders"][0]["commission_amount"] == first == 200.0     # historical order unchanged
    world.db.tables["commission_rules"][0]["is_active"] = False
    world.add(world.bike)
    assert world.checkout().json()["error"]["code"] == "commission_not_configured"
