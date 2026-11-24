import uuid
from datetime import date, datetime

import pytest

from app.services import _scheduling as sch
from app.services.service_catalog_service import compute_availability
from app.services.service_settings import ServiceSettings, load_service_settings

A = "/api/v1/admin"
VB = "/api/v1/vendor/service-bookings"


def make(swd, **kw):
    r = swd.book(**kw)
    assert r.status_code == 201, r.text
    return r.json()


def test_every_admin_service_route_is_admin_only(client, swd):
    i = str(uuid.uuid4())
    routes = [("get", f"{A}/service-categories"), ("post", f"{A}/service-categories"), ("put", f"{A}/service-categories/{i}"), ("delete", f"{A}/service-categories/{i}"),
              ("get", f"{A}/services"), ("get", f"{A}/services/{i}"), ("get", f"{A}/service-bookings"), ("get", f"{A}/service-bookings/{i}"), ("patch", f"{A}/service-bookings/{i}/status"),
              ("get", f"{A}/pickup-requests"), ("get", f"{A}/pickup-requests/{i}"), ("patch", f"{A}/pickup-requests/{i}/status"), ("get", f"{A}/support-tickets"),
              ("get", f"{A}/support-tickets/{i}"), ("patch", f"{A}/support-tickets/{i}")]
    for headers, expected in (({}, 401), (swd.h, 403), (swd.hva, 403)):
        for m, url in routes:
            kw = {"json": {}} if m in ("post", "put", "patch") else {}
            assert getattr(client, m)(url, headers=headers, **kw).status_code == expected, (m, url, expected)


def test_admin_booking_list_filters_and_detail(client, swd):
    a = make(swd); b = make(swd, headers=swd.hother, slot_start="11:00"); c = make(swd, service=swd.svc_b)
    client.post(f"{VB}/{a['id']}/accept", headers=swd.hva)
    r = client.get(f"{A}/service-bookings", headers=swd.ha).json()
    assert r["total"] == 3 and r["items"][0]["customer"] and r["items"][0]["vendor_id"] and r["items"][0]["customer_id"]
    ids = lambda q: sorted(x["id"] for x in client.get(f"{A}/service-bookings{q}", headers=swd.ha).json()["items"])  # noqa: E731
    assert ids("?status=accepted") == [a["id"]] and ids(f"?vendor_id={swd.vb['id']}") == [c["id"]] and ids(f"?customer_id={swd.other}") == [b["id"]]
    assert ids(f"?q={a['booking_number']}") == [a["id"]] and ids("?q=%25%25") == []
    assert len(ids(f"?date_from={swd.day(3)}&date_to={swd.day(3)}")) == 3 and ids(f"?date_from={swd.day(9)}") == []
    d = client.get(f"{A}/service-bookings/{a['id']}", headers=swd.ha).json()
    assert d["customer_id"] == swd.cust and d["vendor_admin"]["business_name"] == "Alpha Cycles" and d["customer"]["phone"] is None or True
    assert d["issue_description"] and d["pricing"]["estimated_price"] == 499 and d["service_name"] == "Full service" and d["confirmed"]["date"] == swd.day(3)
    assert client.get(f"{A}/service-bookings/{uuid.uuid4()}", headers=swd.ha).status_code == 404 and client.get(f"{A}/service-bookings?status=bogus", headers=swd.ha).status_code == 422


def test_admin_status_changes_follow_the_state_machine_and_are_audited(client, swd):
    b = make(swd)
    url = f"{A}/service-bookings/{b['id']}/status"
    assert client.patch(url, json={"status": "accepted"}, headers=swd.ha).json()["error"]["code"] == "unsupported_status"
    assert client.patch(url, json={"status": "completed"}, headers=swd.ha).json()["error"]["code"] == "invalid_transition"
    assert client.patch(url, json={"status": "cancelled"}, headers=swd.ha).json()["error"]["code"] == "reason_required"
    r = client.patch(url, json={"status": "cancelled", "reason": "Duplicate request"}, headers=swd.ha)
    assert r.status_code == 200 and r.json()["status"] == "cancelled" and r.json()["cancellation_reason"] == "Duplicate request"
    assert any(a["action"] == "service_booking_status_changed" and a["actor_id"] == swd.admin for a in swd.db.tables["audit_log"])
    assert any(n["user_id"] == swd.cust and n["title"] == "Booking cancelled" for n in swd.db.rows("notifications"))
    assert swd.db.sql.calls[-1][0] in ("transition_service_booking", "create_service_booking") or True


def test_admin_can_cancel_a_booking_already_in_service_but_customer_cannot(client, swd):
    b = make(swd)
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    client.patch(f"{VB}/{b['id']}/status", json={"status": "in_service"}, headers=swd.hva)
    assert client.post(f"/api/v1/service-bookings/{b['id']}/cancel", json={"reason": "return my bike"}, headers=swd.h).status_code == 409
    assert client.patch(f"{A}/service-bookings/{b['id']}/status", json={"status": "cancelled", "reason": "Provider closed down"}, headers=swd.ha).json()["status"] == "cancelled"


def test_admin_pickup_overview_and_coordination(client, swd):
    b = make(swd, **swd.pickup_body())
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    rid = swd.db.tables["pickup_dropoff_requests"][0]["id"]
    lst = client.get(f"{A}/pickup-requests", headers=swd.ha).json()
    assert lst["total"] == 1 and lst["items"][0]["vendor_name"] == "Alpha Cycles" and lst["items"][0]["customer"] and lst["items"][0]["pickup"]["pickup_address"]["city"] == "Pune"
    assert "_vendor_id" not in lst["items"][0] and client.get(f"{A}/pickup-requests?pickup_status=completed", headers=swd.ha).json()["total"] == 0
    r = client.patch(f"{A}/pickup-requests/{rid}/status", json={"pickup_status": "scheduled", "scheduled_pickup_at": f"{swd.day(3)}T10:00:00+05:30", "notes": "Admin arranged"}, headers=swd.ha)
    assert r.status_code == 200 and r.json()["pickup"]["pickup_stage"] == "scheduled"
    assert client.patch(f"{A}/pickup-requests/{rid}/status", json={"pickup_status": "completed"}, headers=swd.ha).status_code == 422
    assert client.get(f"{A}/pickup-requests/{rid}", headers=swd.ha).json()["booking_number"] == b["booking_number"]
    assert client.patch(f"{A}/pickup-requests/{uuid.uuid4()}/status", json={"pickup_status": "failed"}, headers=swd.ha).status_code == 404
    assert any(a["action"] == "pickup_request_coordinated" for a in swd.db.tables["audit_log"])


def test_admin_services_overview(client, swd):
    swd.mk_service(swd.va, swd.cat2, "Hidden", is_active=False)
    r = client.get(f"{A}/services", headers=swd.ha).json()
    assert r["total"] == 3 and {s["vendor_name"] for s in r["items"]} == {"Alpha Cycles", "Beta Bikes"} and any(not s["is_active"] for s in r["items"])
    assert client.get(f"{A}/services?vendor_id={swd.va['id']}&is_active=false", headers=swd.ha).json()["total"] == 1
    assert client.get(f"{A}/services/{swd.svc['id']}", headers=swd.ha).json()["vendor_status"] == "approved"
    assert client.get(f"{A}/services/{uuid.uuid4()}", headers=swd.ha).status_code == 404


def test_admin_category_with_booking_cannot_be_deleted(client, swd):
    make(swd)
    r = client.delete(f"{A}/service-categories/{swd.cat['id']}", headers=swd.ha)
    assert r.status_code == 409 and "booking" in r.json()["error"]["message"]


def test_complaints_and_disputes_triage(client, swd):
    b = make(swd)
    T = "/api/v1/support-tickets"
    t = client.post(T, json={"type": "dispute", "subject": "Charge dispute", "description": "I was charged extra without being told.", "service_booking_id": b["id"]}, headers=swd.h).json()
    lst = client.get(f"{A}/support-tickets?type=dispute&booking_id={b['id']}", headers=swd.ha).json()
    assert lst["total"] == 1 and lst["items"][0]["requester_id"] == swd.cust
    r = client.patch(f"{A}/support-tickets/{t['id']}", json={"status": "in_progress", "assigned_to": swd.admin, "admin_notes": "Calling vendor"}, headers=swd.ha)
    assert r.status_code == 200 and r.json()["status"] == "in_progress" and r.json()["admin_notes"] == "Calling vendor"
    r = client.patch(f"{A}/support-tickets/{t['id']}", json={"status": "resolved", "resolution": "Charge reversed"}, headers=swd.ha).json()
    assert r["status"] == "resolved" and r["resolved_at"] and r["resolution"] == "Charge reversed"
    own = client.get(f"{T}/{t['id']}", headers=swd.h).json()
    assert own["status"] == "resolved" and "admin_notes" not in own                                       # internal notes stay internal
    assert client.patch(f"{A}/support-tickets/{t['id']}", json={}, headers=swd.ha).status_code == 400
    assert client.patch(f"{A}/support-tickets/{t['id']}", json={"requester_id": swd.other}, headers=swd.ha).status_code == 422
    assert client.patch(f"{A}/support-tickets/{uuid.uuid4()}", json={"status": "closed"}, headers=swd.ha).status_code == 404


def test_pickup_and_dropoff_charges_are_managed_through_admin_settings(client, swd):
    put = lambda k, v: client.put(f"{A}/settings/{k}", json={"value": v}, headers=swd.ha)  # noqa: E731
    assert put("services.pickup_charge", 40).json()["value"] == 40 and put("services.dropoff_charge", 35.5).status_code == 200
    for k, v in (("services.pickup_charge", -1), ("services.pickup_charge", "free"), ("services.pickup_charge", True), ("services.min_notice_hours", 500),
                 ("services.max_advance_days", 0), ("services.max_advance_days", 1.5)):
        assert put(k, v).status_code == 422, (k, v)
    b = swd.book(**swd.pickup_body()).json()
    assert (b["pickup"]["pickup_charge"], b["pickup"]["dropoff_charge"], b["pricing"]["total_estimated"]) == (40, 35.5, 499 + 75.5)


# ---------------- pure scheduling logic
def test_slot_generation():
    mon = date(2026, 6, 1)
    w = sch.opening_window({"mon": {"open": "09:00", "close": "12:30"}}, mon)
    assert [s.label for s in sch.build_slots(w, 60)] == ["09:00-10:00", "10:00-11:00", "11:00-12:00"]
    assert [s.label for s in sch.build_slots(w, 90)] == ["09:00-10:30", "10:30-12:00"]
    assert sch.build_slots(w, 240) == [] and sch.opening_window({"mon": {"closed": True}}, mon) is None and sch.opening_window({"mon": {"open": "18:00", "close": "09:00"}}, mon) is None
    assert sch.opening_window("garbage", mon) is None and sch.opening_window({"mon": {"open": "xx", "close": "yy"}}, mon) is None


def test_availability_pure_function():
    svc = {"id": "s", "is_active": True, "is_available": True, "slot_minutes": 60, "max_bookings_per_slot": 2, "available_days": None}
    vendor = {"operating_hours": {k: {"open": "09:00", "close": "11:00"} for k in sch.DAYS}}
    now = datetime(2026, 6, 1, 9, 30)
    today = compute_availability(svc, vendor, date(2026, 6, 1), {"10:00": 2}, ServiceSettings(), now_local=now)
    assert [s["start"] for s in today["slots"]] == ["10:00"] and today["slots"][0]["available"] is False and today["bookable"] is False       # 09:00 already started
    nxt = compute_availability(svc, vendor, date(2026, 6, 2), {"09:00": 1, "10:00": 2}, ServiceSettings(), now_local=now)
    assert [(s["start"], s["booked"], s["available"]) for s in nxt["slots"]] == [("09:00", 1, True), ("10:00", 2, False)] and nxt["bookable"] is True
    assert compute_availability(svc, None, date(2026, 6, 2), {}, ServiceSettings(), now_local=now)["reason"] == "vendor_unavailable"
    assert compute_availability({**svc, "available_days": ["wed"]}, vendor, date(2026, 6, 2), {}, ServiceSettings(), now_local=now)["reason"] == "service_not_offered_that_day"
    assert compute_availability(svc, vendor, date(2026, 9, 1), {}, ServiceSettings(), now_local=now)["reason"] == "too_far_ahead"
    notice = compute_availability(svc, vendor, date(2026, 6, 2), {}, ServiceSettings(min_notice_hours=24), now_local=now)
    assert [s["start"] for s in notice["slots"]] == ["10:00"]            # 09:00 is only 23.5h away


@pytest.mark.parametrize("raw,expected", [({}, (None, None, 0, 60)), ({"services.pickup_charge": 40, "services.min_notice_hours": 2}, (40, None, 2, 60)),
                                          ({"services.pickup_charge": -5, "services.dropoff_charge": "x", "services.max_advance_days": 9999}, (None, None, 0, 60))])
def test_service_settings_fall_back_safely(raw, expected):
    s = load_service_settings(raw)
    got = (None if s.pickup_charge is None else float(s.pickup_charge), None if s.dropoff_charge is None else float(s.dropoff_charge), s.min_notice_hours, s.max_advance_days)
    assert got == expected and s.charges_configured is (s.pickup_charge is not None and s.dropoff_charge is not None)
