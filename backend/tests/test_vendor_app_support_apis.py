"""Step 8: read-only vendor dashboard aggregate and per-order timeline (added for the Vendor App)."""
import uuid

from tests.test_orders_vendor import V, cod_order, vo_id

DASH = "/api/v1/vendor/dashboard"


def test_dashboard_requires_approved_vendor(client, world, auth):
    assert client.get(DASH).status_code == 401
    assert client.get(DASH, headers=world.h).status_code == 403            # customer
    assert client.get(DASH, headers=world.ha).status_code == 403           # admin is not a vendor
    pending_user = world.db.add_profile(role="vendor")
    world.db.add_vendor(pending_user, status="pending")
    assert client.get(DASH, headers=auth(pending_user)).status_code == 403


def test_dashboard_counts_and_money_come_from_the_database(client, world):
    empty = client.get(DASH, headers=world.hva).json()
    assert empty["orders"]["total"] == 0 and empty["orders"]["sales_total"] == 0 and empty["settlements"] == {}
    cod_order(world, qty=2)
    cod_order(world, qty=1)
    client.post(f"{V}/{vo_id(world, 0)}/accept", headers=world.hva)
    d = client.get(DASH, headers=world.hva).json()
    assert d["orders"]["total"] == 2
    assert d["orders"]["by_status"] == {"accepted": 1, "pending": 1}
    assert d["orders"]["sales_total"] == 0                                   # nothing delivered yet: no revenue is claimed
    assert d["products"]["total"] >= 1
    # delivered order + its settlement record
    vo = world.db.tables["vendor_orders"][0]
    vo.update(status="delivered", commission_amount=200)
    world.db.rows("vendor_settlements").append(world.db.apply_defaults("vendor_settlements", {
        "vendor_id": vo["vendor_id"], "vendor_order_id": vo["id"], "gross_amount": float(vo["subtotal"]), "commission_amount": 200, "deductions_amount": 0,
        "net_amount": float(vo["subtotal"]) - 200, "status": "pending"}))
    d = client.get(DASH, headers=world.hva).json()
    assert d["orders"]["sales_total"] == float(vo["subtotal"]) and d["orders"]["commission_total"] == 200
    assert d["settlements"]["pending"]["net"] == float(vo["subtotal"]) - 200 and d["settlements"]["pending"]["count"] == 1
    assert "paid" not in d["settlements"], "no payout is claimed without a paid settlement record"


def test_dashboard_is_isolated_per_vendor(client, world):
    cod_order(world)
    assert client.get(DASH, headers=world.hva).json()["orders"]["total"] == 1
    assert client.get(DASH, headers=world.hvb).json()["orders"]["total"] == 0


def test_order_timeline_is_only_that_vendors_own_events(client, world):
    o = cod_order(world)
    vid = vo_id(world)
    client.post(f"{V}/{vid}/accept", headers=world.hva)
    world.db.rows("order_status_history").extend([
        {"id": str(uuid.uuid4()), "order_id": o["id"], "vendor_order_id": vid, "from_status": "pending", "to_status": "accepted", "created_at": "2026-01-02T00:00:00+00:00", "note": "ok", "changed_by": world.ua},
        {"id": str(uuid.uuid4()), "order_id": o["id"], "vendor_order_id": str(uuid.uuid4()), "from_status": "pending", "to_status": "rejected", "created_at": "2026-01-02T00:00:00+00:00", "note": "other vendor", "changed_by": None},
        {"id": str(uuid.uuid4()), "order_id": o["id"], "vendor_order_id": None, "from_status": None, "to_status": "confirmed", "created_at": "2026-01-01T00:00:00+00:00", "note": None, "changed_by": None},
    ])
    t = client.get(f"{V}/{vid}/timeline", headers=world.hva)
    assert t.status_code == 200
    assert [e["to_status"] for e in t.json()] == ["accepted"] and t.json()[0]["note"] == "ok"
    assert client.get(f"{V}/{vid}/timeline", headers=world.hvb).status_code == 404     # another vendor's order
    assert client.get(f"{V}/{vid}/timeline", headers=world.h).status_code == 403       # customer
    assert client.get(f"{V}/nope/timeline", headers=world.hva).status_code == 422


def test_vendor_product_list_filters_by_type_and_stock(client, world):
    VP = "/api/v1/vendor/products"
    new_cycle = client.get(VP + "?product_type=new_cycle", headers=world.hva).json()
    assert new_cycle["total"] >= 1 and all(p["product_type"] == "new_cycle" for p in new_cycle["items"])
    assert client.get(VP + "?product_type=spare_part", headers=world.hva).json()["total"] == 0
    assert client.get(VP + "?product_type=bogus", headers=world.hva).status_code == 422
    world.bike["stock_quantity"] = 0
    assert client.get(VP + "?in_stock=false", headers=world.hva).json()["total"] >= 1
    assert client.get(VP + "?in_stock=true", headers=world.hva).json()["total"] == 0


def test_booking_timeline_for_the_owning_vendor_only(client, swd):
    VB = "/api/v1/vendor/service-bookings"
    b = swd.book().json()
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    swd.db.rows("booking_status_history").append({"id": str(uuid.uuid4()), "booking_id": b["id"], "from_status": "pending", "to_status": "accepted", "changed_by": swd.ua,
                                                  "note": "see you", "created_at": "2026-01-02T00:00:00+00:00"})
    t = client.get(f"{VB}/{b['id']}/timeline", headers=swd.hva)
    assert t.status_code == 200
    events = t.json()
    assert events and {"at", "from_status", "to_status", "note", "by_role"} <= set(events[0])
    assert ("accepted", "vendor", "see you") in [(e["to_status"], e["by_role"], e["note"]) for e in events]
    assert client.get(f"{VB}/{b['id']}/timeline", headers=swd.hvb).status_code == 404
    assert client.get(f"{VB}/{b['id']}/timeline", headers=swd.h).status_code == 403
    assert client.get(f"{VB}/not-a-uuid/timeline", headers=swd.hva).status_code == 422


def test_vendor_orders_and_settlements_filter_by_date_range(client, world):
    cod_order(world)
    cod_order(world)
    vos = world.db.tables["vendor_orders"]
    vos[0]["created_at"] = "2026-02-10T10:00:00+05:30"
    vos[1]["created_at"] = "2026-03-20T10:00:00+05:30"
    for vo in vos:                                   # deliver both through the real API so genuine settlement records exist
        client.post(f"{V}/{vo['id']}/accept", headers=world.hva)
        for st in ("preparing", "ready_for_dispatch", "delivered"):
            client.patch(f"{V}/{vo['id']}/status", json={"status": st}, headers=world.hva)
    for st, vo in zip(world.db.tables["vendor_settlements"], vos):
        st["created_at"] = vo["created_at"]
    assert client.get(V, headers=world.hva).json()["total"] == 2
    feb = client.get(V + "?date_from=2026-02-01&date_to=2026-02-28", headers=world.hva).json()
    assert feb["total"] == 1 and feb["items"][0]["id"] == vos[0]["id"]
    assert client.get(V + "?date_from=2026-03-20", headers=world.hva).json()["total"] == 1
    assert client.get(V + "?date_to=2026-02-10", headers=world.hva).json()["total"] == 1             # the end day is inclusive
    S = "/api/v1/vendor/settlements"
    assert client.get(S, headers=world.hva).json()["total"] == 2
    assert client.get(S + "?date_from=2026-03-01&date_to=2026-03-31", headers=world.hva).json()["total"] == 1
    assert client.get(S + "?date_from=bogus", headers=world.hva).status_code == 422
