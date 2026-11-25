"""Cross-application workflows at API level (Customer app <-> Vendor app <-> Admin console <-> FastAPI), using the real routers, services and response schemas
with the in-memory database. These are INTEGRATION tests of our own code; the identity provider, Storage, FCM and payment gateway are test doubles (clearly:
FakePush / FakeProvider / in-memory DB). Live Supabase / Firebase / gateway behaviour is not verified here."""
import pytest

from app.api.v1.endpoints.devices import get_provider_dep
from app.main import app
from tests.test_devices_and_push import FakePush

API = "/api/v1"
TOK = {"cust": "fcm-token-customer-abcdefghijklmnop", "vend": "fcm-token-vendor-abcdefghijklmnopqr", "other": "fcm-token-other-abcdefghijklmnopqrs"}
APP = {"business_name": "Spoke & Co", "business_types": ["bicycle_shop"], "address_line1": "5 Cycle St", "city": "Pune", "state": "Maharashtra",
       "postal_code": "411001", "contact_phone": "+919800000001", "operating_hours": {"mon": {"open": "09:00", "close": "18:00"}}, "pickup_available": True}


@pytest.fixture
def push():
    p = FakePush()
    app.dependency_overrides[get_provider_dep] = lambda: p
    yield p
    app.dependency_overrides.pop(get_provider_dep, None)


def titles(client, headers, **q):
    r = client.get(f"{API}/notifications", headers=headers, params=q).json()
    return [n["title"] for n in r["items"]]


def notes(client, headers):
    return client.get(f"{API}/notifications", headers=headers).json()["items"]


def dispatch(client, admin_headers):
    r = client.post(f"{API}/admin/push/dispatch", headers=admin_headers)
    assert r.status_code == 200, r.text
    return r.json()


def register(client, headers, token, app_):
    assert client.put(f"{API}/devices", json={"token": token, "platform": "android", "app": app_}, headers=headers).status_code == 200


# ================================================================================================ A + B: vendor onboarding -> product -> customer visibility
def test_workflow_a_b_vendor_registers_admin_approves_vendor_lists_admin_moderates_customer_sees(client, db, auth, push):
    admin, customer = db.add_profile(role="admin"), db.add_profile(full_name="Asha Rao")
    ha, hc = auth(admin), auth(customer)
    owner = db.add_profile(role="vendor", full_name="Shop Owner")
    hv = auth(owner)
    cat = db.add_category("new_cycle", "New Cycles")
    register(client, hv, TOK["vend"], "vendor")

    # --- A: vendor app registers; the application is pending and gives no business access
    r = client.post(f"{API}/vendors/register", json=APP, headers=hv)
    assert r.status_code == 201 and r.json()["verification_status"] == "pending"
    assert client.get(f"{API}/auth/me", headers=hv).json()["vendor_verification_status"] == "pending"
    product = {"category_id": cat["id"], "name": "City Bike", "brand": "Hero", "model": "Sprint", "condition": "new", "price": 12500.5, "stock_quantity": 4}
    assert client.post(f"{API}/vendor/products", json=product, headers=hv).status_code == 403          # pending vendors cannot list products
    assert client.get(f"{API}/vendor/orders", headers=hv).status_code == 403

    # admin console sees the application and decides
    pend = client.get(f"{API}/admin/vendors", params={"verification_status": "pending"}, headers=ha).json()
    assert [v["business_name"] for v in pend["items"]] == ["Spoke & Co"]
    vid = pend["items"][0]["id"]
    detail = client.get(f"{API}/admin/vendors/{vid}", headers=ha).json()
    assert detail["address_line1"] == "5 Cycle St" and detail["pickup_available"] is True
    assert client.post(f"{API}/admin/vendors/{vid}/approve", json={}, headers=hv).status_code == 403   # the vendor cannot approve themselves
    assert client.post(f"{API}/admin/vendors/{vid}/approve", json={}, headers=ha).status_code == 200

    # vendor app now shows approved status, has business access and has been told (in-app + push)
    assert client.get(f"{API}/vendors/me/status", headers=hv).json()["can_operate"] is True
    assert "Application approved" in titles(client, hv)
    assert dispatch(client, ha)["sent"] == 1 and push.sent[-1][0] == TOK["vend"] and push.sent[-1][1].data["related_type"] == "vendor_application"

    # --- B: approved vendor lists a product; it is moderated; only then do customers see it
    p = client.post(f"{API}/vendor/products", json=product, headers=hv)
    assert p.status_code == 201 and p.json()["approval_status"] == "pending"
    pid = p.json()["id"]
    assert client.get(f"{API}/products", headers=hc).json()["total"] == 0                               # hidden while pending
    assert client.get(f"{API}/products/{pid}", headers=hc).status_code == 404
    assert [x["name"] for x in client.get(f"{API}/admin/products", params={"moderation_status": "pending"}, headers=ha).json()["items"]] == ["City Bike"]
    assert client.patch(f"{API}/admin/products/{pid}/approval", json={"approval_status": "approved"}, headers=hv).status_code == 403   # vendors cannot approve
    assert client.patch(f"{API}/admin/products/{pid}/approval", json={"approval_status": "rejected", "review_notes": "Photos are unclear"}, headers=ha).status_code == 200
    mine = client.get(f"{API}/vendor/products/{pid}", headers=hv).json()
    assert mine["approval_status"] == "rejected" and mine["review_notes"] == "Photos are unclear"      # vendor app shows the real status and the reason
    assert client.get(f"{API}/products", headers=hc).json()["total"] == 0
    assert client.patch(f"{API}/admin/products/{pid}/approval", json={"approval_status": "approved"}, headers=ha).status_code == 200
    seen = client.get(f"{API}/products", headers=hc).json()
    assert [(x["name"], x["price"], x["in_stock"]) for x in seen["items"]] == [("City Bike", 12500.5, True)]
    assert titles(client, hv)[:2] == ["Product approved", "Product rejected"]                          # newest first
    # ownership: another vendor can neither see nor change it; deactivation hides it again
    other_uid, _ = db.add_approved_vendor("Other Shop")
    assert client.get(f"{API}/vendor/products/{pid}", headers=auth(other_uid)).status_code == 404
    assert client.patch(f"{API}/admin/products/{pid}/status", json={"is_active": False}, headers=ha).status_code == 200
    assert client.get(f"{API}/products", headers=hc).json()["total"] == 0
    assert client.get(f"{API}/vendor/products/{pid}", headers=hv).json()["moderation_status"] == "inactive"
    # a rejected / suspended vendor loses business access immediately
    client.post(f"{API}/admin/vendors/{vid}/suspend", json={"reason": "Policy breach"}, headers=ha)
    assert client.get(f"{API}/vendor/orders", headers=hv).status_code == 403
    assert client.get(f"{API}/vendors/me/status", headers=hv).json()["can_operate"] is False


# ================================================================================================ C + F: product order across all three apps, with money consistency
def test_workflow_c_f_order_flows_customer_vendor_admin_with_consistent_money_notifications_and_push(client, world, push):
    hc, ha, hv, hvb = world.h, world.ha, world.hva, world.hvb
    register(client, hc, TOK["cust"], "customer")
    register(client, hv, TOK["vend"], "vendor")
    register(client, world.hother, TOK["other"], "customer")
    world.add(world.bike, 2)
    world.add(world.pads, 1)
    r = world.checkout({"vendor_id": world.va["id"]})                                                  # one seller at a time (the platform's default policy)
    assert r.status_code == 201, r.text
    order = r.json()["order"]
    oid = order["id"]

    # customer app: the order, with server-computed totals
    detail = client.get(f"{API}/orders/{oid}", headers=hc).json()
    assert detail["status"] == "confirmed" and detail["payment_method"] == "cod" and len(detail["vendor_orders"]) == 1
    vo = detail["vendor_orders"][0]
    assert vo["vendor_name"] == "Alpha" and vo["items"][0]["quantity"] == 2 and vo["items"][0]["unit_price"] == 1000
    # vendor app: sees exactly that order and nothing of the other vendor
    vlist = client.get(f"{API}/vendor/orders", headers=hv).json()
    assert [o["order_number"] for o in vlist["items"]] == [order["order_number"]] and client.get(f"{API}/vendor/orders", headers=hvb).json()["total"] == 0
    # admin console sees it, with customer and payment
    adm = client.get(f"{API}/admin/orders/{oid}", headers=ha).json()
    assert adm["customer"]["id"] == world.cust and adm["payments"][0]["method"] == "cod" and adm["payments"][0]["status"] == "pending"
    # notifications: customer + vendor, each pointing at their own record
    cn, vn = notes(client, hc), notes(client, hv)
    assert [n["title"] for n in cn] == ["Order placed"] and cn[0]["related_type"] == "order" and cn[0]["related_id"] == oid
    assert [n["title"] for n in vn] == ["New order"] and vn[0]["related_type"] == "vendor_order" and vn[0]["related_id"] == vo["id"]
    assert client.get(f"{API}/vendor/orders/{vn[0]['related_id']}", headers=hv).status_code == 200      # the deep link resolves for the right user...
    assert client.get(f"{API}/vendor/orders/{vn[0]['related_id']}", headers=hvb).status_code == 404     # ...and not for another vendor
    assert client.get(f"{API}/orders/{cn[0]['related_id']}", headers=world.hother).status_code == 404    # ...nor another customer
    assert notes(client, world.hother) == []

    # push: both phones get exactly their own notification, once
    out = dispatch(client, ha)
    assert (out["claimed"], out["sent"]) == (2, 2)
    sent = {t: m for t, m in push.sent}
    assert sent[TOK["cust"]].data["related_id"] == oid and sent[TOK["vend"]].data["related_id"] == vo["id"] and TOK["other"] not in sent
    assert dispatch(client, ha)["claimed"] == 0

    # vendor accepts and fulfils; the customer is told at each step, the admin sees the fulfilment
    V = f"{API}/vendor/orders/{vo['id']}"
    assert client.post(f"{V}/accept", headers=hv).status_code == 200
    assert client.post(f"{V}/accept", headers=hv).status_code == 409                                    # not repeatable
    for st in ("preparing", "ready_for_dispatch", "delivered"):
        assert client.patch(f"{V}/status", json={"status": st}, headers=hv).status_code == 200
    seen = titles(client, hc)
    for t in ("Order placed", "Order accepted", "Order preparing", "Order ready for dispatch", "Order delivered"):
        assert seen.count(t) == 1, (t, seen)
    assert client.get(f"{API}/orders/{oid}", headers=hc).json()["status"] == "completed"
    fulfil = client.get(f"{API}/admin/vendor-orders", headers=ha).json()["items"][0]
    assert fulfil["status"] == "delivered" and fulfil["delivered_at"]
    dispatch(client, ha)
    assert [t for t, _ in push.sent].count(TOK["cust"]) == len(notes(client, hc)), "each customer notification was pushed exactly once"
    assert [t for t, _ in push.sent].count(TOK["vend"]) == len(notes(client, hv))

    # cash is collected by an admin; only then is the vendor's settlement ready
    pay = adm["payments"][0]
    assert client.post(f"{API}/admin/payments/{pay['id']}/collect-cod", headers=hc).status_code == 403
    assert client.post(f"{API}/admin/payments/{pay['id']}/collect-cod", headers=ha).status_code == 200

    # ---------------- F: the same numbers everywhere
    final = client.get(f"{API}/admin/orders/{oid}", headers=ha).json()
    vo = final["vendor_orders"][0]
    assert final["total_amount"] == sum(v["total_amount"] for v in final["vendor_orders"]) == final["payments"][0]["amount"] == 2000
    assert vo["total_amount"] == vo["subtotal"] + vo["delivery_charge"] - vo["discount_amount"] == sum(i["line_total"] for i in vo["items"])
    settle = client.get(f"{API}/admin/settlements", headers=ha).json()["items"][0]
    assert (settle["gross_amount"], settle["commission_amount"], settle["net_amount"], settle["status"]) == (2000, 200, 1800, "ready")
    assert settle["gross_amount"] - settle["commission_amount"] - settle["deductions_amount"] == settle["net_amount"]
    vendor_view = client.get(f"{API}/vendor/settlements", headers=hv).json()["items"][0]
    assert (vendor_view["gross_amount"], vendor_view["commission_amount"], vendor_view["net_amount"]) == (2000, 200, 1800)       # vendor app == admin console
    rev = client.get(f"{API}/admin/payments/summary", headers=ha).json()
    assert rev["collected"] == 2000 and rev["commission_earned"] == 200
    rep = client.get(f"{API}/admin/reports/sales", params={"from": "2026-01-01", "to": "2026-12-31"}, headers=ha).json()["data"]
    assert (rep["gross_sales"], rep["commission"], rep["delivered_orders"]) == (2000, 200, 1)
    pay_rep = client.get(f"{API}/admin/reports/payments", params={"from": "2026-01-01", "to": "2026-12-31"}, headers=ha).json()["data"]
    assert pay_rep["collected"] == 2000 and pay_rep["commission"] == 200
    dash = client.get(f"{API}/vendor/dashboard", headers=hv).json()
    assert dash["orders"]["sales_total"] == 2000 and dash["orders"]["commission_total"] == 200
    # a refund is tied to the right payment and cannot exceed it
    rf = client.post(f"{API}/admin/refunds", json={"payment_id": pay["id"], "amount": 500, "reason": "Damaged on arrival"}, headers={**ha, "Idempotency-Key": "wf-refund-0001"}).json()
    assert rf["payment_id"] == pay["id"] and rf["order_id"] == oid
    assert client.post(f"{API}/admin/refunds", json={"payment_id": pay["id"], "amount": 1600, "reason": "too much"}, headers={**ha, "Idempotency-Key": "wf-refund-0002"}).status_code == 409


def test_order_cancellation_notifies_the_vendor_and_restores_stock(client, world, push):
    register(client, world.hva, TOK["vend"], "vendor")
    world.add(world.bike, 2)
    oid = world.checkout().json()["order"]["id"]
    stock = world.bike["stock_quantity"]
    assert client.post(f"{API}/orders/{oid}/cancel", json={"reason": "Changed my mind"}, headers=world.h).status_code == 200
    assert world.bike["stock_quantity"] == stock + 2
    assert [n["title"] for n in notes(client, world.hva)][:1] == ["Order cancelled"]
    vn = notes(client, world.hva)[0]
    assert vn["related_type"] == "vendor_order" and "Changed my mind" in vn["message"]
    # a vendor's own rejection is not echoed back to the vendor, but the customer is told
    world.add(world.bike)
    oid2 = world.checkout().json()["order"]["id"]
    vo2 = client.get(f"{API}/orders/{oid2}", headers=world.h).json()["vendor_orders"][0]["id"]
    assert client.post(f"{API}/vendor/orders/{vo2}/reject", json={"reason": "Out of stock"}, headers=world.hva).status_code == 200
    assert [n["title"] for n in notes(client, world.hva)].count("Order cancelled") == 1
    assert "Order rejected" in titles(client, world.h)
    dispatch(client, world.ha)
    assert all(m.data["related_id"] for _, m in push.sent)


# ================================================================================================ D + E: service booking with doorstep pickup
def test_workflow_d_e_service_booking_pickup_and_return_across_apps(client, swd, push):
    hc, hv, ha = swd.h, swd.hva, swd.ha
    register(client, hc, TOK["cust"], "customer")
    register(client, hv, TOK["vend"], "vendor")
    b = swd.book(**swd.pickup_body(cycle_brand="Hero", cycle_model="Sprint")).json()
    bid = b["id"]
    # vendor app and admin console see the booking; the vendor is told
    assert client.get(f"{API}/vendor/service-bookings", headers=hv).json()["items"][0]["booking_number"] == b["booking_number"]
    assert client.get(f"{API}/vendor/service-bookings", headers=swd.hvb).json()["total"] == 0
    assert client.get(f"{API}/admin/service-bookings/{bid}", headers=ha).json()["customer_id"] == swd.cust
    assert titles(client, hv) == ["New service booking"] and titles(client, hc) == ["Booking received"]
    assert notes(client, hv)[0]["related_type"] == "service_booking" and notes(client, hv)[0]["related_id"] == bid
    assert client.get(f"{API}/service-bookings/{bid}", headers=swd.hother).status_code == 404            # not someone else's booking

    VB = f"{API}/vendor/service-bookings/{bid}"
    assert client.post(f"{VB}/accept", json={}, headers=hv).status_code == 200
    # logistics are separate from the booking status
    pk = client.get(f"{API}/admin/pickup-requests", headers=ha).json()["items"][0]
    assert pk["booking_status"] == "accepted" and pk["pickup"]["pickup_stage"] == "requested"
    when = "2026-12-01T10:30:00+05:30"
    assert client.patch(f"{API}/vendor/pickup-requests/{pk['id']}", json={"scheduled_pickup_at": when, "pickup_status": "scheduled"}, headers=hv).status_code == 200
    track = client.get(f"{API}/service-bookings/{bid}/tracking", headers=hc).json()
    assert track["status"] == "accepted" and track["pickup"]["pickup_stage"] == "scheduled" and track["pickup"]["delivery_stage"] == "requested"
    for st in ("picked_up", "in_service"):
        assert client.patch(f"{VB}/status", json={"status": st}, headers=hv).status_code == 200
    assert client.post(f"{VB}/charges", json={"amount": 150, "reason": "Replaced brake pads"}, headers=hv).status_code == 201
    assert client.post(f"{VB}/notes", json={"note": "Brake pads were worn out"}, headers=hv).status_code == 201
    track = client.get(f"{API}/service-bookings/{bid}/tracking", headers=hc).json()
    assert track["status"] == "in_service" and track["pickup"]["pickup_stage"] == "picked_up" and track["pricing"]["additional_charges_total"] == 150
    for st in ("ready_for_delivery", "completed"):
        assert client.patch(f"{VB}/status", json={"status": st}, headers=hv).status_code == 200
    track = client.get(f"{API}/service-bookings/{bid}/tracking", headers=hc).json()
    assert track["status"] == "completed" and track["pickup"]["delivery_stage"] == "delivered" and track["completed_at"]
    admin_view = client.get(f"{API}/admin/service-bookings/{bid}", headers=ha).json()
    assert admin_view["pricing"]["current_price"] == track["pricing"]["current_price"] == 649         # customer, vendor and admin agree
    assert client.get(f"{VB}", headers=hv).json()["pricing"]["current_price"] == 649
    assert [e["to_status"] for e in client.get(f"{API}/admin/service-bookings/{bid}/timeline", headers=ha).json()][-1] == "completed"

    # customer notifications, in order, each pointing at this booking
    seen = [n["title"] for n in notes(client, hc)]
    for t in ("Booking received", "Booking accepted", "Cycle picked up", "Repair charge updated", "Ready for delivery", "Service completed"):
        assert t in seen, (t, seen)
    assert all(n["related_id"] == bid for n in notes(client, hc) if n["related_type"] == "service_booking") and "Repair started" in seen
    # push: one per notification, only to the right phone, none twice
    total_customer, total_vendor = len(notes(client, hc)), len(notes(client, hv))
    dispatch(client, ha)
    dispatch(client, ha)
    got = [t for t, _ in push.sent]
    assert got.count(TOK["cust"]) == total_customer and got.count(TOK["vend"]) == total_vendor
    # repeating a finished step creates neither a second state change nor a second notification
    assert client.patch(f"{VB}/status", json={"status": "completed"}, headers=hv).status_code == 409
    assert len(notes(client, hc)) == total_customer


def test_service_cancellation_by_the_customer_notifies_vendor_and_admin_once(client, swd, push):
    register(client, swd.hva, TOK["vend"], "vendor")
    bid = swd.book().json()["id"]
    assert client.post(f"{API}/service-bookings/{bid}/cancel", json={"reason": "Plans changed"}, headers=swd.h).status_code == 200
    assert client.post(f"{API}/service-bookings/{bid}/cancel", json={"reason": "again please"}, headers=swd.h).status_code == 409
    assert titles(client, swd.hva).count("Booking cancelled") == 1
    assert titles(client, swd.ha).count("Booking cancelled") == 1 and "Plans changed" in notes(client, swd.hva)[0]["message"]


# ================================================================================================ authentication across the three apps
def test_one_identity_provider_three_roles_and_roles_always_come_from_the_database(client, db, auth, push):
    customer, vendor_uid, admin = db.add_profile(), db.add_profile(role="vendor"), db.add_profile(role="admin")
    db.add_vendor(vendor_uid, "approved")
    forged = {"user_metadata": {"role": "admin"}, "app_metadata": {"role": "admin"}, "role_claim": "admin"}
    for uid, role in ((customer, "customer"), (vendor_uid, "vendor"), (admin, "admin")):
        me = client.get(f"{API}/auth/me", headers=auth(uid, extra=forged)).json()
        assert me["role"] == role and me["id"] == uid and me["status"] == "active"
    # the customer and vendor tokens never open admin endpoints, whatever the token claims
    for uid in (customer, vendor_uid):
        for path in ("/admin/customers", "/admin/orders", "/admin/reports/orders", "/admin/push/status", "/admin/coupons"):
            assert client.get(f"{API}{path}", headers=auth(uid, extra=forged)).status_code == 403, path
    # every app's API surface refuses the other roles
    assert client.get(f"{API}/vendor/orders", headers=auth(customer)).status_code == 403
    assert client.get(f"{API}/cart", headers=auth(vendor_uid)).status_code == 403
    assert client.get(f"{API}/cart", headers=auth(admin)).status_code == 403
    # a deactivated account loses access to its own app at once, even with a still-valid token
    db.profile(customer)["status"] = "inactive"
    assert client.get(f"{API}/cart", headers=auth(customer)).status_code == 403
    assert client.put(f"{API}/devices", json={"token": TOK["cust"], "platform": "android", "app": "customer"}, headers=auth(customer)).status_code == 403
    assert client.get(f"{API}/auth/me", headers=auth(customer)).status_code == 200                      # /me still tells the app why
