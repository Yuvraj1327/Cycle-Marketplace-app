import uuid

SC = "/api/v1/service-categories"
S = "/api/v1/services"
VS = "/api/v1/vendor/services"
ASC = "/api/v1/admin/service-categories"


# ---------------- categories
def test_public_categories_active_only_in_order_with_counts(client, swd):
    swd.db.rows("service_categories").append(swd.db.apply_defaults("service_categories", {"name": "Hidden", "slug": "hidden", "sort_order": 0, "is_active": False}))
    r = client.get(SC)
    assert r.status_code == 200 and r.headers["cache-control"] == "public, max-age=60"
    assert [c["name"] for c in r.json()] == ["General Servicing", "Puncture Repair"]
    assert [c["service_count"] for c in r.json()] == [2, 0]
    d = client.get(f"{SC}/{swd.cat['id']}").json()
    assert d["name"] == "General Servicing" and {s["name"] for s in d["services"]} == {"Full service", "Basic"}
    assert client.get(f"{SC}/{swd.db.tables['service_categories'][-1]['id']}").status_code == 404
    assert client.get(f"{SC}/{uuid.uuid4()}").status_code == 404


def test_admin_category_crud_and_safe_delete(client, swd):
    body = {"name": "Gear Adjustment", "sort_order": 4, "description": "Indexing"}
    assert client.post(ASC, json=body).status_code == 401
    for h in (swd.h, swd.hva):
        assert client.post(ASC, json=body, headers=h).status_code == 403
        assert client.get(ASC, headers=h).status_code == 403
    r = client.post(ASC, json=body, headers=swd.ha)
    assert r.status_code == 201 and r.json()["slug"] == "gear-adjustment" and r.json()["is_active"] is True
    assert client.post(ASC, json={"name": "Gear  Adjustment"}, headers=swd.ha).json()["slug"] == "gear-adjustment-2"
    cid = r.json()["id"]
    off = client.put(f"{ASC}/{cid}", json={"is_active": False, "description": None}, headers=swd.ha)
    assert off.status_code == 200 and off.json()["is_active"] is False
    assert cid not in [c["id"] for c in client.get(SC).json()] and cid in [c["id"] for c in client.get(ASC, headers=swd.ha).json()]
    assert client.put(f"{ASC}/{cid}", json={}, headers=swd.ha).status_code == 400
    assert client.put(f"{ASC}/{uuid.uuid4()}", json={"name": "zz zz"}, headers=swd.ha).status_code == 404
    assert client.post(ASC, json={"name": "x"}, headers=swd.ha).status_code == 422
    assert client.delete(f"{ASC}/{swd.cat['id']}", headers=swd.ha).json()["error"]["code"] == "category_in_use"       # vendor services use it
    assert client.delete(f"{ASC}/{cid}", headers=swd.ha).status_code == 204
    assert client.delete(f"{ASC}/{cid}", headers=swd.ha).status_code == 404


# ---------------- vendor services
def vs_body(cat, **kw):
    return {"service_category_id": cat["id"], "name": "Puncture fix", "price": 150.5, "estimated_duration_minutes": 30, "slot_minutes": 30, **kw}


def test_vendor_creates_updates_and_deactivates_own_service(client, swd):
    r = client.post(VS, json=vs_body(swd.cat2), headers=swd.hva)
    assert r.status_code == 201
    s = r.json()
    assert s["price"] == 150.5 and s["is_active"] is True and s["is_available"] is True and s["category"]["name"] == "Puncture Repair" and s["max_bookings_per_slot"] == 1
    p = client.patch(f"{VS}/{s['id']}", json={"price": 175, "estimated_duration_minutes": 45, "available_days": ["mon", "sat"], "max_bookings_per_slot": 2}, headers=swd.hva)
    assert p.status_code == 200 and p.json()["price"] == 175 and p.json()["available_days"] == ["mon", "sat"]
    off = client.patch(f"{VS}/{s['id']}", json={"is_available": False}, headers=swd.hva).json()
    assert off["is_available"] is False
    assert client.patch(f"{VS}/{s['id']}", json={"is_active": False}, headers=swd.hva).json()["is_active"] is False
    assert client.get(f"{S}/{s['id']}").status_code == 404                                         # hidden from customers
    assert client.get(f"{VS}", headers=swd.hva).json()["total"] == 2
    assert client.get(f"{VS}?is_active=false", headers=swd.hva).json()["total"] == 1
    rep = client.put(f"{VS}/{s['id']}", json={**vs_body(swd.cat2, name="Puncture fix v2"), "is_active": True}, headers=swd.hva)
    assert rep.status_code == 200 and rep.json()["name"] == "Puncture fix v2" and rep.json()["is_active"] is True


def test_vendor_service_validation_and_duplicates(client, swd):
    for bad in ({"price": -1}, {"price": 10_000_001}, {"price": 1.234}, {"name": "x"}, {"estimated_duration_minutes": 0}, {"slot_minutes": 10}, {"slot_minutes": 62},
                {"max_bookings_per_slot": 0}, {"max_bookings_per_slot": 21}, {"available_days": ["funday"]}, {"available_days": ["mon", "mon"]}, {"vendor_id": str(uuid.uuid4())},
                {"service_category_id": "nope"}, {"is_active": True}):
        assert client.post(VS, json=vs_body(swd.cat2, **bad), headers=swd.hva).status_code == 422, bad
    assert client.post(VS, json=vs_body(swd.cat2, service_category_id=str(uuid.uuid4())), headers=swd.hva).json()["error"]["code"] == "invalid_category"
    swd.cat2["is_active"] = False
    assert client.post(VS, json=vs_body(swd.cat2), headers=swd.hva).json()["error"]["code"] == "invalid_category"        # inactive category
    swd.cat2["is_active"] = True
    assert client.post(VS, json=vs_body(swd.cat2), headers=swd.hva).status_code == 201
    assert client.post(VS, json=vs_body(swd.cat2), headers=swd.hva).status_code == 409                                    # same name in category


def test_vendors_cannot_create_categories_or_touch_other_vendors(client, swd):
    assert client.post(ASC, json={"name": "My Own Category"}, headers=swd.hva).status_code == 403
    theirs = swd.svc_b
    path = f"{VS}/{theirs['id']}"
    assert client.get(path, headers=swd.hva).status_code == 404
    assert client.patch(path, json={"price": 1}, headers=swd.hva).status_code == 404
    assert client.put(path, json={**vs_body(swd.cat), "is_active": True}, headers=swd.hva).status_code == 404
    assert client.delete(path, headers=swd.hva).status_code == 404
    assert theirs["price"] == 499.0 and theirs["is_active"]
    assert client.get(VS, headers=swd.hva).json()["total"] == 1


def test_only_approved_vendors_manage_services(client, swd, auth):
    for status in ("pending", "rejected", "suspended"):
        uid = swd.db.add_profile(role="vendor"); swd.db.add_vendor(uid, status)
        h = auth(uid)
        assert client.post(VS, json=vs_body(swd.cat2), headers=h).status_code == 403
        assert client.get(VS, headers=h).status_code == 403
    for h in ({}, swd.h, swd.ha):
        assert client.get(VS, headers=h).status_code in (401, 403)


def test_delete_removes_unbooked_service_but_only_deactivates_booked_one(client, swd):
    fresh = client.post(VS, json=vs_body(swd.cat2), headers=swd.hva).json()
    assert client.delete(f"{VS}/{fresh['id']}", headers=swd.hva).json()["result"] == "deleted"
    assert client.get(f"{VS}/{fresh['id']}", headers=swd.hva).status_code == 404
    assert swd.book().status_code == 201
    r = client.delete(f"{VS}/{swd.svc['id']}", headers=swd.hva).json()
    assert r["result"] == "deactivated"
    kept = client.get(f"{VS}/{swd.svc['id']}", headers=swd.hva).json()
    assert kept["is_active"] is False and kept["is_available"] is False
    b = client.get("/api/v1/service-bookings", headers=swd.h).json()["items"][0]
    assert b["service_name"] == "Full service" and b["current_price"] == 499            # history untouched


def test_price_change_never_alters_existing_bookings(client, swd):
    bid = swd.book().json()["id"]
    client.patch(f"{VS}/{swd.svc['id']}", json={"price": 999, "name": "Premium service"}, headers=swd.hva)
    b = client.get(f"/api/v1/service-bookings/{bid}", headers=swd.h).json()
    assert b["pricing"]["estimated_price"] == 499 and b["service_name"] == "Full service"


# ---------------- public browse
def test_browse_filters_and_hides_ineligible(client, swd):
    swd.mk_service(swd.va, swd.cat2, "Patch", price=120.0)
    swd.mk_service(swd.va, swd.cat2, "Hidden", is_active=False)
    swd.mk_service(swd.va, swd.cat2, "Paused", is_available=False)
    swd.vb["verification_status"] = "suspended"
    r = client.get(S).json()
    assert {x["name"] for x in r["items"]} == {"Full service", "Patch"} and r["total"] == 2
    assert [x["name"] for x in client.get(f"{S}?category_id={swd.cat2['id']}").json()["items"]] == ["Patch"]
    assert client.get(f"{S}?vendor_id={swd.va['id']}").json()["total"] == 2
    assert [x["name"] for x in client.get(f"{S}?q=patch").json()["items"]] == ["Patch"]
    assert client.get(f"{S}?q=%25%25").json()["items"] == []
    assert client.get(f"/api/v1/vendors/{swd.va['id']}/services").json()["total"] == 2
    assert client.get(f"/api/v1/vendors/{swd.vb['id']}/services").json()["total"] == 0          # suspended provider: nothing public
    assert client.get(f"{S}?limit=500").status_code == 422


def test_service_details_include_provider_without_private_data(client, swd):
    d = client.get(f"{S}/{swd.svc['id']}").json()
    assert d["price"] == 499 and d["estimated_duration_minutes"] == 120 and d["category"]["name"] == "General Servicing"
    p = d["provider"]
    assert p["business_name"] == "Alpha Cycles" and p["pickup_available"] is True and p["service_area_postal_codes"] == ["411001", "411002"] and p["operating_hours"]["mon"]["open"] == "09:00"
    flat = str(d)
    assert "contact_phone" not in flat and "address_line1" not in flat and "contact_email" not in flat and "user_id" not in flat
    assert client.get(f"{S}/{uuid.uuid4()}").status_code == 404 and client.get(f"{S}/nope").status_code == 422


# ---------------- availability
def test_availability_slots_from_operating_hours(client, swd):
    r = client.get(f"{S}/{swd.svc['id']}/availability?date={swd.day(3)}")
    d = r.json()
    assert r.status_code == 200 and d["bookable"] is True and d["reason"] is None and d["slot_minutes"] == 60
    assert [s["start"] for s in d["slots"]] == [f"{h:02d}:00" for h in range(9, 18)]
    assert d["slots"][0] == {"start": "09:00", "end": "10:00", "capacity": 1, "booked": 0, "available": True}


def test_availability_respects_accepted_bookings_only(client, swd):
    b1 = swd.book(preferred_date=swd.day(3), slot_start="10:00").json()
    pending = lambda: next(s for s in client.get(f"{S}/{swd.svc['id']}/availability?date={swd.day(3)}").json()["slots"] if s["start"] == "10:00")  # noqa: E731
    assert pending()["available"] is True and pending()["booked"] == 0                  # pending bookings do not hold a slot
    assert client.post(f"/api/v1/vendor/service-bookings/{b1['id']}/accept", headers=swd.hva).status_code == 200
    assert pending() == {"start": "10:00", "end": "11:00", "capacity": 1, "booked": 1, "available": False}
    r = swd.book(headers=swd.hother, preferred_date=swd.day(3), slot_start="10:00")
    assert r.status_code == 409 and r.json()["error"]["code"] == "slot_full"
    swd.svc["max_bookings_per_slot"] = 2
    assert pending()["available"] is True and swd.book(headers=swd.hother, preferred_date=swd.day(3), slot_start="10:00").status_code == 201


def test_availability_reasons(client, swd):
    url = lambda d, s=None: f"{S}/{(s or swd.svc)['id']}/availability?date={d}"  # noqa: E731
    assert client.get(url(swd.day(-2))).json()["reason"] == "date_in_past"
    assert client.get(url(swd.day(200))).json()["reason"] == "too_far_ahead"
    swd.svc["available_days"] = ["mon"]
    from datetime import date as d
    day = d.fromisoformat(swd.day(3))
    expected = "service_not_offered_that_day" if day.weekday() != 0 else None
    assert client.get(url(day.isoformat())).json()["reason"] == expected
    swd.svc["available_days"] = None
    swd.va["operating_hours"] = {k: {"closed": True} for k in ("mon", "tue", "wed", "thu", "fri", "sat", "sun")}
    assert client.get(url(swd.day(3))).json()["reason"] == "vendor_closed"
    swd.va["operating_hours"] = {}
    r = client.get(url(swd.day(3))).json()
    assert r["reason"] == "vendor_hours_not_configured" and r["slots"] == [] and r["bookable"] is False
    assert client.get(url("2026-13-01")).status_code == 422 and client.get(f"{S}/{swd.svc['id']}/availability").status_code == 422
    assert client.get(url(swd.day(3), {"id": str(uuid.uuid4())})).status_code == 404


def test_slot_length_and_notice_period(client, swd):
    swd.svc["slot_minutes"] = 90
    slots = client.get(f"{S}/{swd.svc['id']}/availability?date={swd.day(3)}").json()["slots"]
    assert slots[0]["start"] == "09:00" and slots[0]["end"] == "10:30" and slots[-1]["end"] <= "18:00" and len(slots) == 6
    swd.svc["slot_minutes"] = 60
    swd.setting("services.min_notice_hours", 24 * 4)
    assert client.get(f"{S}/{swd.svc['id']}/availability?date={swd.day(3)}").json()["reason"] == "no_slots_left"        # inside the notice period
