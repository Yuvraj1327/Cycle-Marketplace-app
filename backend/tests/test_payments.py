import uuid

P = "/api/v1/payments"


def online(world, qty=1):
    world.add(world.bike, qty)
    r = world.checkout({"payment_method": "online"})
    assert r.status_code == 201, r.text
    return r.json()


def ev(i, kind, order, **kw):
    return {"id": i, "type": kind, "order": order, **kw}


def test_webhook_rejects_bad_or_missing_signature_and_changes_nothing(client, world):
    online(world)
    po = world.db.tables["payments"][0]["provider_order_id"]
    good = ev("e1", "payment.succeeded", po, payment="pay_1", amount="1000", currency="INR")
    for sig in ("", "deadbeef", "0" * 64):
        r = world.webhook(good, sig=sig)
        assert r.status_code == 400 and r.json()["error"]["code"] == "invalid_signature"
    assert world.db.tables["payments"][0]["status"] == "processing" and world.db.tables["orders"][0]["status"] == "pending"
    assert not world.db.tables.get("payment_events")


def test_webhook_needs_a_configured_provider(client, world):
    world.provider.configured = False
    world.provider.parse_webhook = lambda h, b: (_ for _ in ()).throw(__import__("app.integrations.payments.base", fromlist=["x"]).PaymentProviderNotConfigured())
    r = world.webhook(ev("e1", "payment.succeeded", "po"))
    assert r.status_code == 503 and r.json()["error"]["code"] == "payment_provider_not_configured"


def test_verified_success_confirms_order_and_releases_vendor_order(client, world):
    online(world)
    po = world.db.tables["payments"][0]["provider_order_id"]
    r = world.webhook(ev("e1", "payment.succeeded", po, payment="pay_1", amount="1000", currency="INR"))
    assert r.status_code == 200 and r.json() == {"received": 1, "results": [{"event_id": "e1", "outcome": "applied"}]}
    o = world.db.tables["orders"][0]
    assert o["status"] == "confirmed" and o["payment_status"] == "successful" and world.db.tables["vendor_orders"][0]["released_at"]
    pay = client.get(f"{P}/{world.db.tables['payments'][0]['id']}", headers=world.h).json()
    assert pay["status"] == "successful" and pay["amount_due"] == 0 and pay["paid_at"]


def test_duplicate_webhook_is_idempotent(client, world):
    online(world)
    po = world.db.tables["payments"][0]["provider_order_id"]
    e = ev("e1", "payment.succeeded", po, payment="pay_1", amount="1000", currency="INR")
    assert world.webhook(e).json()["results"][0]["outcome"] == "applied"
    assert world.webhook(e).json()["results"][0]["outcome"] == "duplicate"
    assert world.webhook(ev("e2", "payment.succeeded", po, amount="1000", currency="INR")).json()["results"][0]["outcome"] == "already_applied"
    assert len(world.db.tables["payments"]) == 1 and len(world.db.tables["payment_events"]) == 2 and world.bike["stock_quantity"] == 4     # stock untouched


def test_amount_or_currency_mismatch_never_marks_paid(client, world):
    online(world)
    po = world.db.tables["payments"][0]["provider_order_id"]
    assert world.webhook(ev("e1", "payment.succeeded", po, amount="1", currency="INR")).json()["results"][0]["outcome"] == "amount_mismatch"
    assert world.webhook(ev("e2", "payment.succeeded", po, amount="1000", currency="USD")).json()["results"][0]["outcome"] == "amount_mismatch"
    assert world.webhook(ev("e3", "payment.succeeded", po)).json()["results"][0]["outcome"] == "amount_mismatch"            # no amount at all
    pay = world.db.tables["payments"][0]
    assert pay["status"] == "processing" and pay["needs_review"] is True and world.db.tables["orders"][0]["status"] == "pending"


def test_failed_payment_does_not_confirm_and_can_be_retried(client, world):
    online(world)
    po = world.db.tables["payments"][0]["provider_order_id"]
    assert world.webhook(ev("f1", "payment.failed", po, reason="card declined", amount="1000", currency="INR")).json()["results"][0]["outcome"] == "applied"
    o, pay = world.db.tables["orders"][0], world.db.tables["payments"][0]
    assert pay["status"] == "failed" and pay["failure_reason"] == "card declined" and o["status"] == "pending" and o["payment_status"] == "failed"
    assert world.bike["stock_quantity"] == 4                                   # reservation kept for the retry window
    r = client.post(f"{P}/create", json={"order_id": o["id"]}, headers=world.h)
    assert r.status_code == 200 and r.json()["status"] == "processing" and r.json()["client_payload"]["order_id"].startswith("po_")
    assert len(world.db.tables["payments"]) == 2
    again = client.post(f"{P}/create", json={"order_id": o["id"]}, headers=world.h)
    assert again.json()["id"] == r.json()["id"] and len(world.db.tables["payments"]) == 2         # idempotent: same open attempt
    new_po = again.json()["provider_order_id"]
    assert world.webhook(ev("s1", "payment.succeeded", new_po, payment="pay_2", amount="1000", currency="INR")).json()["results"][0]["outcome"] == "applied"
    assert world.db.tables["orders"][0]["status"] == "confirmed"


def test_pending_payment_event_and_late_failure_after_success(client, world):
    online(world)
    po = world.db.tables["payments"][0]["provider_order_id"]
    world.db.tables["payments"][0]["status"] = "pending"
    assert world.webhook(ev("p1", "payment.processing", po)).json()["results"][0]["outcome"] == "applied"
    assert world.db.tables["payments"][0]["status"] == "processing" and world.db.tables["orders"][0]["status"] == "pending"
    world.webhook(ev("s1", "payment.succeeded", po, amount="1000", currency="INR"))
    assert world.webhook(ev("f9", "payment.failed", po)).json()["results"][0]["outcome"] == "ignored"
    assert world.db.tables["payments"][0]["status"] == "successful"


def test_unknown_payment_is_acknowledged_not_errored(client, world):
    online(world)
    assert world.webhook(ev("u1", "payment.succeeded", "po_unknown", amount="1", currency="INR")).json()["results"][0]["outcome"] == "unmatched"


def test_payment_create_rules(client, world):
    world.add(world.bike)
    cod = world.checkout().json()["order"]
    assert client.post(f"{P}/create", json={"order_id": cod["id"]}, headers=world.h).json()["error"]["code"] == "not_online_order"
    o = online(world)["order"]
    assert client.post(f"{P}/create", json={"order_id": o["id"]}, headers=world.hother).status_code == 404            # someone else's order
    assert client.post(f"{P}/create", json={"order_id": str(uuid.uuid4())}, headers=world.h).status_code == 404
    assert client.post(f"{P}/create", json={"order_id": o["id"]}).status_code == 401
    assert client.post(f"{P}/create", json={"order_id": o["id"]}, headers=world.ha).status_code == 403
    world.provider.configured = False
    assert client.post(f"{P}/create", json={"order_id": o["id"]}, headers=world.h).json()["error"]["code"] == "payment_provider_not_configured"
    world.provider.configured = True
    po = world.db.tables["payments"][-1]["provider_order_id"]
    world.webhook(ev("s1", "payment.succeeded", po, amount="1000", currency="INR"))
    assert client.post(f"{P}/create", json={"order_id": o["id"]}, headers=world.h).json()["error"]["code"] == "order_not_payable"


def test_payment_status_is_private(client, world):
    o = online(world)
    pid = o["payment"]["id"]
    assert client.get(f"{P}/{pid}", headers=world.h).status_code == 200
    assert client.get(f"{P}/{pid}", headers=world.hother).status_code == 404
    assert client.get(f"{P}/{pid}", headers=world.hva).status_code == 403
    assert client.get(f"{P}/{pid}").status_code == 401
    assert client.get(f"/api/v1/orders/{o['order']['id']}/payment", headers=world.hother).status_code == 404
    assert len(client.get(f"/api/v1/orders/{o['order']['id']}/payment", headers=world.h).json()) == 1


def test_late_payment_after_cancellation_requests_a_refund_not_confirmation(client, world):
    o = online(world)["order"]
    po = world.db.tables["payments"][0]["provider_order_id"]
    assert client.post(f"/api/v1/orders/{o['id']}/cancel", json={"reason": "changed my mind"}, headers=world.h).status_code == 200
    assert world.bike["stock_quantity"] == 5
    out = world.webhook(ev("late1", "payment.succeeded", po, payment="pay_9", amount="1000", currency="INR")).json()["results"][0]["outcome"]
    assert out == "applied_late_refund_requested"
    assert world.db.tables["orders"][0]["status"] == "cancelled" and world.db.tables["refunds"][0]["status"] == "requested" and world.bike["stock_quantity"] == 5


def test_cod_collection_only_by_admin_and_only_once_dispatched(client, world):
    world.add(world.bike)
    pid = world.checkout().json()["payment"]["id"]
    vo = world.db.tables["vendor_orders"][0]["id"]
    url = f"/api/v1/admin/payments/{pid}/collect-cod"
    for h in ({}, world.h, world.hva):
        assert client.post(url, headers=h).status_code in (401, 403)
    assert client.post(url, headers=world.ha).json()["error"]["code"] == "not_dispatched"
    for step in ("accept", "status"):
        pass
    client.post(f"/api/v1/vendor/orders/{vo}/accept", headers=world.hva)
    for st in ("preparing", "ready_for_dispatch", "out_for_delivery"):
        client.patch(f"/api/v1/vendor/orders/{vo}/status", json={"status": st}, headers=world.hva)
    assert client.get(f"{P}/{pid}", headers=world.h).json()["amount_due"] == 1000
    assert client.post(url, headers=world.ha).status_code == 200
    pay = world.db.tables["payments"][0]
    assert pay["status"] == "successful" and pay["recorded_by"] == world.admin and world.db.tables["orders"][0]["payment_status"] == "successful"
    assert client.post(url, headers=world.ha).json()["error"]["code"] == "not_collectable"
    assert client.get(f"{P}/{pid}", headers=world.h).json()["amount_due"] == 0


def test_vendor_and_customer_cannot_mark_payments_paid_any_other_way(client, world):
    world.add(world.bike)
    pid = world.checkout().json()["payment"]["id"]
    vo = world.db.tables["vendor_orders"][0]["id"]
    for body in ({"payment_status": "successful"}, {"status": "paid"}, {"status": "successful"}):
        r = client.patch(f"/api/v1/vendor/orders/{vo}/status", json=body, headers=world.hva)
        assert r.status_code == 422
    assert world.db.tables["payments"][0]["status"] == "pending"
    assert client.patch(f"/api/v1/payments/{pid}", json={"status": "successful"}, headers=world.h).status_code == 405


def test_reconcile_applies_provider_truth_through_the_same_path(client, world):
    online(world)
    pid = world.db.tables["payments"][0]["id"]
    url = f"/api/v1/admin/payments/{pid}/reconcile"
    assert client.post(url, headers=world.h).status_code == 403
    world.provider.state = "succeeded"
    assert client.post(url, headers=world.ha).json()["outcome"] == "applied"
    assert world.db.tables["orders"][0]["status"] == "confirmed"
    assert client.post(url, headers=world.ha).json()["outcome"] == "duplicate"
    assert any(a["action"] == "payment_reconciled" for a in world.db.tables["audit_log"])
