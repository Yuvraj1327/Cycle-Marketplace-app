import uuid

ORD = "/api/v1/orders"
V = "/api/v1/vendor/orders"


def cod_order(world, product=None, qty=1, **body):
    world.add(product or world.bike, qty)
    r = world.checkout(body)
    assert r.status_code == 201, r.text
    return r.json()["order"]


def vo_id(world, i=0):
    return world.db.tables["vendor_orders"][i]["id"]


def test_customer_lists_and_filters_only_own_orders(client, world):
    a = cod_order(world)
    cod_order(world, qty=1)
    world.db.tables["orders"][1]["status"] = "completed"
    other_cart = world.db.apply_defaults("carts", {"user_id": world.other}); world.db.rows("carts").append(other_cart)
    r = client.get(ORD, headers=world.h).json()
    assert r["total"] == 2 and r["items"][0]["order_number"] and set(r["items"][0]) >= {"item_count", "vendor_count", "payment_status", "total_amount"}
    assert client.get(ORD + "?status=completed", headers=world.h).json()["total"] == 1
    assert client.get(ORD + "?status=bogus", headers=world.h).status_code == 422
    assert client.get(ORD, headers=world.hother).json()["total"] == 0
    assert client.get(ORD + "?limit=1&page=2", headers=world.h).json()["items"][0]["id"] != client.get(ORD + "?limit=1", headers=world.h).json()["items"][0]["id"]
    assert client.get(ORD).status_code == 401 and client.get(ORD, headers=world.hva).status_code == 403 and a


def test_order_detail_is_a_stable_snapshot_and_private(client, world):
    o = cod_order(world, qty=2)
    world.bike["name"], world.bike["price"] = "Renamed Bike", 9999.0          # vendor later edits the listing
    d = client.get(f"{ORD}/{o['id']}", headers=world.h).json()
    assert d["vendor_orders"][0]["items"][0]["product_name"] == "Bike" and d["vendor_orders"][0]["items"][0]["unit_price"] == 1000 and d["total_amount"] == 2000
    world.db.tables["products"].remove(world.bike)                               # ...or deletes it
    assert client.get(f"{ORD}/{o['id']}", headers=world.h).json()["vendor_orders"][0]["items"][0]["product_name"] == "Bike"
    assert client.get(f"{ORD}/{o['id']}", headers=world.hother).status_code == 404
    assert client.get(f"{ORD}/{uuid.uuid4()}", headers=world.h).status_code == 404
    assert client.get(f"{ORD}/nope", headers=world.h).status_code == 422


def test_tracking_timeline(client, world):
    o = cod_order(world)
    vid = vo_id(world)
    client.post(f"{V}/{vid}/accept", headers=world.hva)
    world.db.rows("order_status_history").append({"id": str(uuid.uuid4()), "order_id": o["id"], "vendor_order_id": vid, "from_status": "pending", "to_status": "accepted",
                                                  "created_at": "2026-01-02T00:00:00+00:00", "note": None, "changed_by": world.ua})
    t = client.get(f"{ORD}/{o['id']}/tracking", headers=world.h).json()
    assert t["status"] == "confirmed" and t["vendor_orders"][0]["status"] == "accepted" and t["timeline"][-1]["to_status"] == "accepted"
    assert client.get(f"{ORD}/{o['id']}/tracking", headers=world.hother).status_code == 404


def test_customer_cancel_restores_stock_once_and_records_reason(client, world):
    o = cod_order(world, qty=2)
    assert world.bike["stock_quantity"] == 3
    r = client.post(f"{ORD}/{o['id']}/cancel", json={"reason": "Ordered by mistake"}, headers=world.h)
    d = r.json()
    assert r.status_code == 200 and d["status"] == "cancelled" and d["cancelled_reason"] == "Ordered by mistake" and d["can_cancel"] is False
    assert world.bike["stock_quantity"] == 5 and d["vendor_orders"][0]["status"] == "cancelled"
    again = client.post(f"{ORD}/{o['id']}/cancel", json={"reason": "again"}, headers=world.h)
    assert again.status_code == 409 and again.json()["error"]["code"] == "not_cancellable" and world.bike["stock_quantity"] == 5
    assert world.db.tables["payments"][0]["status"] == "cancelled" and not world.db.tables.get("refunds")           # nothing was paid -> no refund


def test_customer_cancel_rules(client, world):
    o = cod_order(world)
    assert client.post(f"{ORD}/{o['id']}/cancel", json={"reason": "x"}, headers=world.h).status_code == 422                # reason too short
    assert client.post(f"{ORD}/{o['id']}/cancel", json={}, headers=world.h).status_code == 422
    assert client.post(f"{ORD}/{o['id']}/cancel", json={"reason": "not mine"}, headers=world.hother).status_code == 404
    assert client.post(f"{ORD}/{o['id']}/cancel", json={"reason": "not mine"}, headers=world.hva).status_code == 403
    vid = vo_id(world)
    for st in ("accept",):
        client.post(f"{V}/{vid}/{st}", headers=world.hva)
    client.patch(f"{V}/{vid}/status", json={"status": "preparing"}, headers=world.hva)
    r = client.post(f"{ORD}/{o['id']}/cancel", json={"reason": "too late now"}, headers=world.h)
    assert r.status_code == 409 and r.json()["error"]["code"] == "not_cancellable" and world.db.tables["orders"][0]["status"] == "confirmed"
    assert client.get(f"{ORD}/{o['id']}", headers=world.h).json()["can_cancel"] is False


def test_cancelling_a_completed_order_is_refused(client, world):
    o = cod_order(world)
    world.db.tables["orders"][0]["status"] = "completed"
    assert client.post(f"{ORD}/{o['id']}/cancel", json={"reason": "refund please"}, headers=world.h).json()["error"]["code"] == "not_cancellable"


def test_cancelling_a_paid_online_order_requests_but_never_claims_a_refund(client, world):
    world.add(world.bike)
    o = world.checkout({"payment_method": "online"}).json()["order"]
    po = world.db.tables["payments"][0]["provider_order_id"]
    world.webhook({"id": "e1", "type": "payment.succeeded", "order": po, "payment": "pay_1", "amount": "1000", "currency": "INR"})
    r = client.post(f"{ORD}/{o['id']}/cancel", json={"reason": "changed my mind"}, headers=world.h)
    assert r.status_code == 200 and r.json()["payment_status"] == "successful"                     # NOT "refunded"
    ref = world.db.tables["refunds"][0]
    assert ref["status"] == "requested" and ref["amount"] == 1000 and ref["processed_at"] is None and world.db.tables["payments"][0]["refunded_amount"] == 0


# ---------------- vendor
def test_vendor_sees_only_released_orders_of_their_own(client, world):
    cod_order(world)                                                      # Alpha, COD -> visible
    world.add(world.pads)
    world.checkout({"payment_method": "online"})                          # Beta, online unpaid -> not released
    a = client.get(V, headers=world.hva).json()
    assert a["total"] == 1 and a["items"][0]["status"] == "pending" and a["items"][0]["payment_method"] == "cod"
    assert client.get(V, headers=world.hvb).json()["total"] == 0           # Beta's order is unpaid: invisible
    po = world.db.tables["payments"][-1]["provider_order_id"]
    world.webhook({"id": "e1", "type": "payment.succeeded", "order": po, "amount": "250.50", "currency": "INR"})
    assert client.get(V, headers=world.hvb).json()["total"] == 1                # appears after verified payment
    assert client.get(V + "?status=delivered", headers=world.hva).json()["total"] == 0
    assert client.get(V).status_code == 401 and client.get(V, headers=world.h).status_code == 403 and client.get(V, headers=world.ha).status_code == 403


def test_vendor_order_detail_has_fulfilment_info_but_no_account_data(client, world):
    cod_order(world, qty=2)
    d = client.get(f"{V}/{vo_id(world)}", headers=world.hva).json()
    assert d["delivery_address"]["recipient_name"] == "Asha" and d["delivery_address"]["phone"] == "+919800000001" and d["items"][0]["quantity"] == 2
    assert d["payment_method"] == "cod" and d["payment_status"] == "pending" and d["commission_amount"] == 200 and d["net_payable"] == 1800
    assert "email" not in str(d) and "customer_id" not in d


def test_vendor_isolation(client, world):
    cod_order(world)
    vid = vo_id(world)
    assert client.get(f"{V}/{vid}", headers=world.hvb).status_code == 404
    assert client.post(f"{V}/{vid}/accept", headers=world.hvb).status_code == 404
    assert client.post(f"{V}/{vid}/reject", json={"reason": "not mine to reject"}, headers=world.hvb).status_code == 404
    assert client.patch(f"{V}/{vid}/status", json={"status": "preparing"}, headers=world.hvb).status_code == 404
    assert world.db.tables["vendor_orders"][0]["status"] == "pending" and world.bike["stock_quantity"] == 4


def test_vendor_state_machine(client, world):
    cod_order(world)
    vid = vo_id(world)
    bad = client.patch(f"{V}/{vid}/status", json={"status": "preparing"}, headers=world.hva)
    assert bad.status_code == 409 and bad.json()["error"]["code"] == "invalid_transition"            # cannot skip accept
    assert client.patch(f"{V}/{vid}/status", json={"status": "delivered"}, headers=world.hva).status_code == 409
    for dedicated in ("accepted", "rejected", "pending"):
        assert client.patch(f"{V}/{vid}/status", json={"status": dedicated}, headers=world.hva).json()["error"]["code"] == "use_dedicated_endpoint"
    assert client.post(f"{V}/{vid}/accept", headers=world.hva).json()["status"] == "accepted"
    assert client.post(f"{V}/{vid}/accept", headers=world.hva).status_code == 409                       # not twice
    assert client.post(f"{V}/{vid}/reject", json={"reason": "changed my mind"}, headers=world.hva).status_code == 409     # only from pending
    for st in ("preparing", "ready_for_dispatch", "out_for_delivery", "delivered"):
        r = client.patch(f"{V}/{vid}/status", json={"status": st}, headers=world.hva)
        assert r.status_code == 200 and r.json()["status"] == st, r.text
    assert world.db.tables["orders"][0]["status"] == "completed" and world.db.tables["vendor_settlements"][0]["status"] == "pending"
    assert client.patch(f"{V}/{vid}/status", json={"status": "cancelled", "note": "too late now"}, headers=world.hva).status_code == 409


def test_vendor_reject_restores_stock_and_cancels_the_order(client, world):
    o = cod_order(world, qty=2)
    vid = vo_id(world)
    assert client.post(f"{V}/{vid}/reject", json={}, headers=world.hva).status_code == 422                   # reason required
    r = client.post(f"{V}/{vid}/reject", json={"reason": "Out of stock at the shop"}, headers=world.hva)
    assert r.status_code == 200 and r.json()["status"] == "rejected" and r.json()["rejection_reason"] == "Out of stock at the shop"
    assert world.bike["stock_quantity"] == 5 and world.db.tables["orders"][0]["status"] == "cancelled"
    assert client.get(f"{ORD}/{o['id']}", headers=world.h).json()["vendor_orders"][0]["rejection_reason"] == "Out of stock at the shop"
    assert client.post(f"{V}/{vid}/accept", headers=world.hva).status_code == 409


def test_vendor_cancel_needs_a_reason(client, world):
    cod_order(world)
    vid = vo_id(world)
    client.post(f"{V}/{vid}/accept", headers=world.hva)
    assert client.patch(f"{V}/{vid}/status", json={"status": "cancelled"}, headers=world.hva).json()["error"]["code"] == "reason_required"
    assert client.patch(f"{V}/{vid}/status", json={"status": "cancelled", "note": "Cannot fulfil"}, headers=world.hva).status_code == 200
    assert world.bike["stock_quantity"] == 5


def test_unreleased_online_order_cannot_be_acted_on(client, world):
    world.add(world.bike)
    world.checkout({"payment_method": "online"})
    vid = vo_id(world)
    assert client.post(f"{V}/{vid}/accept", headers=world.hva).status_code == 404       # not even visible to the vendor yet


def test_suspended_or_unapproved_vendors_cannot_manage_orders(client, world, auth):
    cod_order(world)
    vid = vo_id(world)
    world.va["verification_status"] = "suspended"
    for call in (lambda: client.get(V, headers=world.hva), lambda: client.post(f"{V}/{vid}/accept", headers=world.hva),
                 lambda: client.patch(f"{V}/{vid}/status", json={"status": "preparing"}, headers=world.hva), lambda: client.get(V + "/settlements", headers=world.hva)):
        assert call().status_code == 403
    assert world.db.tables["vendor_orders"][0]["status"] == "pending"


def test_multi_vendor_partial_rejection_keeps_the_rest_alive(client, world):
    world.db.rows("platform_settings").append({"key": "checkout.multi_vendor_policy", "value": "allow_multi_vendor"})
    world.add(world.bike); world.add(world.pads)
    world.checkout()
    beta = next(v for v in world.db.tables["vendor_orders"] if v["vendor_id"] == world.vb["id"])
    client.post(f"{V}/{beta['id']}/reject", json={"reason": "cannot supply"}, headers=world.hvb)
    assert world.db.tables["orders"][0]["status"] == "confirmed" and world.pads["stock_quantity"] == 4 and world.bike["stock_quantity"] == 4
    alpha = next(v for v in world.db.tables["vendor_orders"] if v["vendor_id"] == world.va["id"])
    for step in ("accept",):
        client.post(f"{V}/{alpha['id']}/accept", headers=world.hva)
    for st in ("preparing", "ready_for_dispatch", "delivered"):
        client.patch(f"{V}/{alpha['id']}/status", json={"status": st}, headers=world.hva)
    assert world.db.tables["orders"][0]["status"] == "completed"                        # delivered + rejected => complete


def test_vendor_settlements_view_is_own_only(client, world):
    cod_order(world)
    vid = vo_id(world)
    client.post(f"{V}/{vid}/accept", headers=world.hva)
    for st in ("preparing", "ready_for_dispatch", "delivered"):
        client.patch(f"{V}/{vid}/status", json={"status": st}, headers=world.hva)
    s = client.get("/api/v1/vendor/settlements", headers=world.hva).json()
    assert s["total"] == 1 and s["items"][0]["gross_amount"] == 1000 and s["items"][0]["commission_amount"] == 100 and s["items"][0]["net_amount"] == 900
    assert client.get("/api/v1/vendor/settlements", headers=world.hvb).json()["total"] == 0


def test_ownership_is_enforced_in_the_service_even_without_row_level_security(world):
    """Defence in depth: use a SERVICE-level client (no RLS at all) and the service layer must still refuse other people's data."""
    import pytest

    from app.core.dependencies import ApprovedVendor, CurrentUser
    from app.core.exceptions import NotFoundError
    from app.services.order_service import OrderService
    from app.services.vendor_order_service import VendorOrderService
    from tests.conftest import SERVICE, FakeClient

    world.add(world.bike)
    order = world.checkout().json()["order"]
    vid = world.db.tables["vendor_orders"][0]["id"]
    raw = FakeClient(world.db, SERVICE)
    stranger = CurrentUser(id=world.other, role="customer", status="active", email=None, auth_phone=None, profile={}, claims=None)
    with pytest.raises(NotFoundError):
        OrderService(raw, raw).get(stranger, uuid.UUID(order["id"]))
    with pytest.raises(NotFoundError):
        OrderService(raw, raw).cancel(stranger, uuid.UUID(order["id"]), "not mine")
    other_vendor = ApprovedVendor(user=stranger, vendor=world.vb)
    with pytest.raises(NotFoundError):
        VendorOrderService(raw, raw).get(other_vendor, uuid.UUID(vid))
    assert not any(fn == "cancel_order" for fn, _ in world.db.sql.calls)
