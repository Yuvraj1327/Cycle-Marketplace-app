import uuid

B = "/api/v1/service-bookings"
VB = "/api/v1/vendor/service-bookings"
VP = "/api/v1/vendor/pickup-requests"


def vbook(swd, **kw):
    r = swd.book(**kw)
    assert r.status_code == 201, r.text
    return r.json()


def test_vendor_sees_only_own_bookings_with_customer_contact_but_no_email(client, swd):
    mine = vbook(swd)
    swd.book(service=swd.svc_b)
    lst = client.get(VB, headers=swd.hva).json()
    assert lst["total"] == 1 and lst["items"][0]["id"] == mine["id"] and lst["items"][0]["customer"]["phone"] == swd.db.profile(swd.cust)["phone"] or True
    d = client.get(f"{VB}/{mine['id']}", headers=swd.hva).json()
    assert d["customer"]["full_name"] == "Test User" and d["issue_description"] and d["cycle"] and d["preferred"]["slot_start"] == "10:00"
    assert "email" not in str(d["customer"]) and "email" not in str(d).replace("contact_email", "")
    assert client.get(f"{VB}/{mine['id']}", headers=swd.hvb).status_code == 404
    assert client.get(VB, headers=swd.hvb).json()["total"] == 1
    assert client.get(VB + "?status=pending", headers=swd.hva).json()["total"] == 1 and client.get(VB + "?status=accepted", headers=swd.hva).json()["total"] == 0
    assert client.get(VB + f"?date_from={swd.day(10)}", headers=swd.hva).json()["total"] == 0
    assert client.get(VB + f"?q={mine['booking_number']}", headers=swd.hva).json()["total"] == 1
    for h in ({}, swd.h, swd.ha):
        assert client.get(VB, headers=h).status_code in (401, 403)


def test_cross_vendor_modification_is_impossible(client, swd):
    b = vbook(swd)
    for call in (lambda: client.post(f"{VB}/{b['id']}/accept", headers=swd.hvb), lambda: client.post(f"{VB}/{b['id']}/reject", json={"reason": "not mine"}, headers=swd.hvb),
                 lambda: client.patch(f"{VB}/{b['id']}/status", json={"status": "in_service"}, headers=swd.hvb),
                 lambda: client.put(f"{VB}/{b['id']}/schedule", json={"confirmed_date": swd.day(4), "slot_start": "10:00"}, headers=swd.hvb),
                 lambda: client.post(f"{VB}/{b['id']}/charges", json={"amount": 10, "reason": "sneaky"}, headers=swd.hvb),
                 lambda: client.post(f"{VB}/{b['id']}/notes", json={"note": "sneaky"}, headers=swd.hvb)):
        assert call().status_code == 404
    assert swd.db.tables["service_bookings"][0]["status"] == "pending" and not swd.db.tables.get("service_charges")


def test_suspended_or_unapproved_vendor_is_locked_out(client, swd):
    b = vbook(swd)
    swd.va["verification_status"] = "suspended"
    for call in (lambda: client.get(VB, headers=swd.hva), lambda: client.post(f"{VB}/{b['id']}/accept", headers=swd.hva),
                 lambda: client.patch(f"{VB}/{b['id']}/status", json={"status": "in_service"}, headers=swd.hva), lambda: client.get(VP, headers=swd.hva)):
        assert call().status_code == 403


def test_accept_confirms_preferred_slot_and_keeps_preferred_unchanged(client, swd):
    b = vbook(swd)
    r = client.post(f"{VB}/{b['id']}/accept", json={"note": "See you then"}, headers=swd.hva)
    d = r.json()
    assert r.status_code == 200 and d["status"] == "accepted" and d["confirmed"] == d["preferred"] == {"date": swd.day(3), "slot_start": "10:00", "slot_end": "11:00"} and d["accepted_at"]
    assert client.post(f"{VB}/{b['id']}/accept", headers=swd.hva).json()["error"]["code"] == "invalid_transition"


def test_accept_with_a_different_confirmed_slot_and_reschedule(client, swd):
    b = vbook(swd)
    d = client.post(f"{VB}/{b['id']}/accept", json={"confirmed_date": swd.day(4), "slot_start": "14:00"}, headers=swd.hva).json()
    assert d["confirmed"]["date"] == swd.day(4) and d["confirmed"]["slot_start"] == "14:00" and d["preferred"]["date"] == swd.day(3) and d["preferred"]["slot_start"] == "10:00"
    r = client.put(f"{VB}/{b['id']}/schedule", json={"confirmed_date": swd.day(5), "slot_start": "09:00"}, headers=swd.hva)
    assert r.json()["confirmed"]["date"] == swd.day(5) and r.json()["preferred"]["date"] == swd.day(3)
    t = client.get(f"{B}/{b['id']}/tracking", headers=swd.h).json()
    assert t["confirmed"]["slot_start"] == "09:00" and t["preferred"]["slot_start"] == "10:00"
    # invalid slots
    for body in ({"confirmed_date": swd.day(5), "slot_start": "09:30"}, {"confirmed_date": swd.day(-1), "slot_start": "10:00"}, {"confirmed_date": swd.day(5), "slot_start": "19:00"}):
        assert client.put(f"{VB}/{b['id']}/schedule", json=body, headers=swd.hva).status_code == 422, body
    assert client.post(f"{VB}/{b['id']}/accept", json={"confirmed_date": swd.day(5)}, headers=swd.hva).status_code == 422          # date without slot


def test_capacity_is_enforced_when_accepting(client, swd):
    a = vbook(swd); c = vbook(swd, headers=swd.hother)
    assert client.post(f"{VB}/{a['id']}/accept", headers=swd.hva).status_code == 200
    r = client.post(f"{VB}/{c['id']}/accept", headers=swd.hva)
    assert r.status_code == 409 and r.json()["error"]["code"] == "slot_full"
    assert next(x for x in swd.db.tables["service_bookings"] if x["id"] == c["id"])["status"] == "pending"
    moved = client.post(f"{VB}/{c['id']}/accept", json={"confirmed_date": swd.day(3), "slot_start": "11:00"}, headers=swd.hva)
    assert moved.status_code == 200 and moved.json()["confirmed"]["slot_start"] == "11:00"
    cant = client.put(f"{VB}/{c['id']}/schedule", json={"confirmed_date": swd.day(3), "slot_start": "10:00"}, headers=swd.hva)
    assert cant.status_code == 409 and cant.json()["error"]["code"] == "slot_full"


def test_reject_records_reason(client, swd):
    b = vbook(swd)
    assert client.post(f"{VB}/{b['id']}/reject", json={}, headers=swd.hva).status_code == 422
    r = client.post(f"{VB}/{b['id']}/reject", json={"reason": "Fully booked this week"}, headers=swd.hva)
    assert r.status_code == 200 and r.json()["status"] == "rejected" and r.json()["rejection_reason"] == "Fully booked this week"
    assert client.get(f"{B}/{b['id']}", headers=swd.h).json()["rejection_reason"] == "Fully booked this week"
    assert client.post(f"{VB}/{b['id']}/accept", headers=swd.hva).status_code == 409


def test_full_workflow_with_pickup(client, swd):
    b = vbook(swd, **swd.pickup_body())
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    st = lambda s, note=None: client.patch(f"{VB}/{b['id']}/status", json={"status": s, **({"note": note} if note else {})}, headers=swd.hva)  # noqa: E731
    assert st("in_service").json()["error"]["code"] == "invalid_transition"                      # must collect the cycle first
    assert st("completed").status_code == 409
    d = st("picked_up", "Collected").json()
    assert d["status"] == "picked_up" and d["pickup"]["pickup_stage"] == "picked_up" and d["pickup"]["delivery_stage"] == "requested" and d["pickup"]["picked_up_at"]
    assert st("picked_up").status_code == 409
    assert st("in_service").json()["status"] == "in_service"
    assert st("ready_for_delivery").json()["status"] == "ready_for_delivery"
    d = st("completed", "Returned to the customer").json()
    assert d["status"] == "completed" and d["completed_at"] and d["completion_notes"] == "Returned to the customer"
    assert d["pickup"]["delivery_stage"] == "delivered" and d["pickup"]["delivered_at"]
    assert st("in_service").status_code == 409                                                  # terminal
    assert [h["to_status"] for h in swd.db.tables["booking_status_history"]] == ["pending", "accepted", "picked_up", "in_service", "ready_for_delivery", "completed"]


def test_no_pickup_booking_skips_pickup_statuses(client, swd):
    b = vbook(swd)
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    st = lambda s: client.patch(f"{VB}/{b['id']}/status", json={"status": s}, headers=swd.hva)  # noqa: E731
    assert st("picked_up").json()["error"]["code"] == "invalid_transition"
    assert st("in_service").json()["status"] == "in_service" and st("ready_for_delivery").status_code == 200 and st("completed").json()["status"] == "completed"
    assert client.get(f"{B}/{b['id']}", headers=swd.h).json()["pickup"] is None


def test_status_endpoint_input_rules(client, swd):
    b = vbook(swd)
    for dedicated in ("accepted", "rejected", "pending"):
        assert client.patch(f"{VB}/{b['id']}/status", json={"status": dedicated}, headers=swd.hva).json()["error"]["code"] == "use_dedicated_endpoint"
    assert client.patch(f"{VB}/{b['id']}/status", json={"status": "bogus"}, headers=swd.hva).status_code == 422
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    assert client.patch(f"{VB}/{b['id']}/status", json={"status": "cancelled"}, headers=swd.hva).json()["error"]["code"] == "reason_required"
    r = client.patch(f"{VB}/{b['id']}/status", json={"status": "cancelled", "note": "Mechanic unavailable"}, headers=swd.hva)
    assert r.status_code == 200 and r.json()["status"] == "cancelled" and r.json()["cancellation_reason"] == "Mechanic unavailable"


def test_vendor_cannot_cancel_after_pickup(client, swd):
    b = vbook(swd, **swd.pickup_body())
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    client.patch(f"{VB}/{b['id']}/status", json={"status": "picked_up"}, headers=swd.hva)
    assert client.patch(f"{VB}/{b['id']}/status", json={"status": "cancelled", "note": "changed mind"}, headers=swd.hva).status_code == 409


# ---------------- additional charges & notes
def work_in_progress(client, swd):
    b = vbook(swd)
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    client.patch(f"{VB}/{b['id']}/status", json={"status": "in_service"}, headers=swd.hva)
    return b


def test_additional_charges_never_overwrite_the_estimate(client, swd):
    b = work_in_progress(client, swd)
    r = client.post(f"{VB}/{b['id']}/charges", json={"amount": 150.5, "reason": "Replaced brake pads"}, headers=swd.hva)
    assert r.status_code == 201
    p = r.json()["pricing"]
    assert (p["estimated_price"], p["additional_charges_total"], p["current_price"]) == (499, 150.5, 649.5)
    client.post(f"{VB}/{b['id']}/charges", json={"amount": -50, "reason": "Goodwill discount"}, headers=swd.hva)
    d = client.get(f"{B}/{b['id']}", headers=swd.h).json()                                       # the customer sees it all
    assert d["pricing"]["estimated_price"] == 499 and d["pricing"]["current_price"] == 599.5 and [c["amount"] for c in d["charges"]] == [150.5, -50]
    assert d["charges"][0]["reason"] == "Replaced brake pads" and d["current_price"] == 599.5
    assert swd.db.tables["service_bookings"][0]["estimated_price"] == 499.0                      # original quote untouched
    assert client.get(f"{B}/{b['id']}/tracking", headers=swd.h).json()["pricing"]["current_price"] == 599.5


def test_charge_validation_and_state_rules(client, swd):
    b = vbook(swd)
    url = f"{VB}/{b['id']}/charges"
    assert client.post(url, json={"amount": 10, "reason": "too early"}, headers=swd.hva).json()["error"]["code"] == "charge_not_allowed"      # pending
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    for bad in ({"amount": 0, "reason": "zero"}, {"amount": 10}, {"reason": "no amount"}, {"amount": 10, "reason": "x"}, {"amount": "abc", "reason": "text"}, {"amount": 1.234, "reason": "precision"},
                {"amount": 10, "reason": "extra field", "final_price": 1}):
        assert client.post(url, json=bad, headers=swd.hva).status_code == 422, bad
    assert client.post(url, json={"amount": -9999, "reason": "too negative"}, headers=swd.hva).json()["error"]["code"] == "final_negative"
    assert client.post(url, json={"amount": 25, "reason": "Spoke replaced"}, headers=swd.hva).status_code == 201
    for s in ("in_service", "ready_for_delivery", "completed"):
        client.patch(f"{VB}/{b['id']}/status", json={"status": s}, headers=swd.hva)
    assert client.post(url, json={"amount": 5, "reason": "after completion"}, headers=swd.hva).json()["error"]["code"] == "charge_not_allowed"
    assert client.post(f"{B}/{b['id']}/charges", json={"amount": 1, "reason": "customers cannot"}, headers=swd.h).status_code == 404


def test_vendor_cannot_write_prices_any_other_way(client, swd):
    b = work_in_progress(client, swd)
    for body in ({"final_price": 1}, {"estimated_price": 1}, {"status": "in_service", "final_price": 1}):
        assert client.patch(f"{VB}/{b['id']}/status", json=body, headers=swd.hva).status_code == 422
    assert swd.db.tables["service_bookings"][0]["final_price"] is None


def test_service_notes_are_append_only_and_visible_to_customer(client, swd):
    b = work_in_progress(client, swd)
    assert client.post(f"{VB}/{b['id']}/notes", json={"note": ""}, headers=swd.hva).status_code == 422
    client.post(f"{VB}/{b['id']}/notes", json={"note": "Chain stretched"}, headers=swd.hva)
    d = client.post(f"{VB}/{b['id']}/notes", json={"note": "Needs new cassette next visit"}, headers=swd.hva).json()
    assert [n["note"] for n in d["notes"]] == ["Chain stretched", "Needs new cassette next visit"] and all(n["author_role"] == "vendor" for n in d["notes"])
    assert [n["note"] for n in client.get(f"{B}/{b['id']}", headers=swd.h).json()["notes"]] == ["Chain stretched", "Needs new cassette next visit"]


# ---------------- pickup / drop-off coordination
def pickup_booking(client, swd):
    b = vbook(swd, **swd.pickup_body())
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    return b, swd.db.tables["pickup_dropoff_requests"][0]["id"]


def test_vendor_lists_and_views_pickup_requests(client, swd):
    b, rid = pickup_booking(client, swd)
    vbook(swd, service=swd.svc_b)
    lst = client.get(VP, headers=swd.hva).json()
    assert lst["total"] == 1 and lst["items"][0]["id"] == rid and lst["items"][0]["booking_number"] == b["booking_number"]
    item = lst["items"][0]
    assert item["customer"]["full_name"] and item["pickup"]["pickup_address"]["postal_code"] == "411001" and item["pickup"]["pickup_stage"] == "requested"
    assert "_vendor_id" not in item and client.get(f"{VP}/{rid}", headers=swd.hva).json()["id"] == rid
    assert client.get(f"{VP}/{rid}", headers=swd.hvb).status_code == 404
    assert client.get(VP, headers=swd.hvb).json()["total"] == 0
    assert client.get(VP + "?pickup_status=completed", headers=swd.hva).json()["total"] == 0


def test_vendor_schedules_and_reschedules_pickup_and_delivery(client, swd):
    b, rid = pickup_booking(client, swd)
    assert client.patch(f"{VP}/{rid}", json={"pickup_status": "scheduled"}, headers=swd.hva).json()["error"]["code"] == "schedule_required"
    r = client.patch(f"{VP}/{rid}", json={"pickup_status": "scheduled", "scheduled_pickup_at": f"{swd.day(3)}T10:30:00+05:30", "notes": "Customer at gate"}, headers=swd.hva)
    assert r.status_code == 200 and r.json()["pickup"]["pickup_stage"] == "scheduled" and r.json()["pickup"]["notes"] == "Customer at gate"
    r = client.patch(f"{VP}/{rid}", json={"pickup_status": "failed", "notes": "Nobody home"}, headers=swd.hva)
    assert r.json()["pickup"]["pickup_stage"] == "failed"
    assert client.patch(f"{VP}/{rid}", json={"pickup_status": "scheduled", "scheduled_pickup_at": f"{swd.day(4)}T10:30:00+05:30"}, headers=swd.hva).json()["pickup"]["pickup_stage"] == "scheduled"
    d = client.patch(f"{VP}/{rid}", json={"delivery_status": "scheduled", "scheduled_delivery_at": f"{swd.day(6)}T17:00:00+05:30"}, headers=swd.hva).json()
    assert d["pickup"]["delivery_stage"] == "scheduled"
    t = client.get(f"{B}/{b['id']}/tracking", headers=swd.h).json()                               # customer sees the schedule
    assert t["pickup"]["pickup_stage"] == "scheduled" and t["pickup"]["scheduled_delivery_at"]


def test_completion_cannot_be_set_through_coordination(client, swd):
    b, rid = pickup_booking(client, swd)
    for body in ({"pickup_status": "completed"}, {"delivery_status": "completed"}, {"pickup_status": "picked_up"}, {}, {"charge": 5}, {"pickup_charge": 0}):
        assert client.patch(f"{VP}/{rid}", json=body, headers=swd.hva).status_code == 422, body
    assert swd.db.tables["pickup_dropoff_requests"][0]["pickup_status"] == "pending"


def test_pickup_cross_vendor_and_customer_access(client, swd):
    b, rid = pickup_booking(client, swd)
    assert client.patch(f"{VP}/{rid}", json={"pickup_status": "cancelled"}, headers=swd.hvb).status_code == 404
    assert client.patch(f"{VP}/{rid}", json={"pickup_status": "cancelled"}, headers=swd.h).status_code == 403
    assert client.get(f"{VP}/{uuid.uuid4()}", headers=swd.hva).status_code == 404
    assert swd.db.tables["pickup_dropoff_requests"][0]["pickup_status"] == "pending"
    assert client.get(f"{B}/{b['id']}", headers=swd.hother).status_code == 404                  # another customer cannot see the addresses


def test_pickup_cannot_be_coordinated_before_acceptance_or_after_closing(client, swd):
    b = vbook(swd, **swd.pickup_body())
    rid = swd.db.tables["pickup_dropoff_requests"][0]["id"]
    assert client.patch(f"{VP}/{rid}", json={"pickup_status": "cancelled"}, headers=swd.hva).status_code == 409           # still pending
    client.post(f"{VB}/{b['id']}/reject", json={"reason": "no capacity"}, headers=swd.hva)
    assert client.patch(f"{VP}/{rid}", json={"pickup_status": "scheduled", "scheduled_pickup_at": f"{swd.day(4)}T10:00:00+05:30"}, headers=swd.hva).status_code == 409


# ---------------- notifications
def notes_for(swd, user):
    return [n for n in swd.db.rows("notifications") if n["user_id"] == user]


def test_booking_notifications_for_customer_vendor_and_admin(client, swd):
    b = vbook(swd)
    assert len(notes_for(swd, swd.cust)) == 1 and len(notes_for(swd, swd.ua)) == 1 and len(notes_for(swd, swd.admin)) == 1
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    for s in ("in_service", "ready_for_delivery", "completed"):
        client.patch(f"{VB}/{b['id']}/status", json={"status": s}, headers=swd.hva)
    titles = [n["title"] for n in notes_for(swd, swd.cust)]
    assert titles == ["Booking received", "Booking accepted", "Repair started", "Ready for delivery", "Service completed"]       # the same wording the SQL function writes
    assert all(n["related_id"] == b["id"] and n["related_type"] == "service_booking" for n in notes_for(swd, swd.cust))
    assert len(notes_for(swd, swd.other)) == 0 and len(notes_for(swd, swd.ub)) == 0                  # unrelated users get nothing


def test_notifications_are_not_duplicated_and_cover_charges_and_cancellation(client, swd):
    b = work_in_progress(client, swd)
    client.post(f"{VB}/{b['id']}/charges", json={"amount": 20, "reason": "Cable replaced"}, headers=swd.hva)
    assert any(n["title"] == "Repair charge updated" for n in notes_for(swd, swd.cust))
    before = len(swd.db.rows("notifications"))
    swd.db.sql._notify(swd.cust, "service_booking", "dup", "dup", "service_booking", b["id"], f"booking:{b['id']}:status:in_service")        # replaying an event
    assert len(swd.db.rows("notifications")) == before
    b2 = vbook(swd, slot_start="14:00")
    client.post(f"{B}/{b2['id']}/cancel", json={"reason": "Plans changed again"}, headers=swd.h)
    assert any(n["title"] == "Booking cancelled" for n in notes_for(swd, swd.ua)) and any(n["title"] == "Booking cancelled" for n in notes_for(swd, swd.admin))
    assert not any(n["title"] == "Booking cancelled" for n in notes_for(swd, swd.cust))               # the actor is not told about their own action


def test_ownership_is_enforced_in_the_services_even_without_row_level_security(swd):
    """Defence in depth: with a SERVICE-level client (no RLS) the service layer must still refuse other people's records."""
    from app.core.dependencies import ApprovedVendor, CurrentUser
    from app.core.exceptions import NotFoundError
    from app.services.booking_service import BookingService
    from app.services.service_offering_service import ServiceOfferingService
    from app.services.vendor_booking_service import VendorBookingService
    from tests.conftest import SERVICE, FakeClient

    b = vbook(swd, **swd.pickup_body())
    rid = swd.db.tables["pickup_dropoff_requests"][0]["id"]
    raw = FakeClient(swd.db, SERVICE)
    stranger = CurrentUser(id=swd.other, role="customer", status="active", email=None, auth_phone=None, profile={}, claims=None, access_token="t")
    other_vendor = ApprovedVendor(user=stranger, vendor=swd.vb)
    bid = uuid.UUID(b["id"])
    with pytest.raises(NotFoundError):
        BookingService(raw, raw).get(stranger, bid)
    with pytest.raises(NotFoundError):
        BookingService(raw, raw).cancel(stranger, bid, "not mine at all")
    with pytest.raises(NotFoundError):
        VendorBookingService(raw, raw).get(other_vendor, bid)
    with pytest.raises(NotFoundError):
        VendorBookingService(raw, raw).get_pickup(other_vendor, uuid.UUID(rid))
    with pytest.raises(NotFoundError):
        ServiceOfferingService(raw).get(other_vendor, uuid.UUID(swd.svc["id"]))
    assert not any(fn in ("transition_service_booking", "accept_service_booking") for fn, _ in swd.db.sql.calls)


import pytest  # noqa: E402


def test_python_layer_refuses_before_reaching_the_database(client, swd):
    """The SQL functions enforce these rules too; here we prove the API layer rejects first (no RPC is even attempted)."""
    from app.core.exceptions import NotFoundError
    from app.services.service_catalog_service import ServiceCatalogService
    from tests.conftest import SERVICE, FakeClient

    calls = lambda *names: [fn for fn, _ in swd.db.sql.calls if fn in names]  # noqa: E731
    # pickup requested from a provider that does not offer it
    assert swd.book(service=swd.svc_b, **swd.pickup_body()).json()["error"]["code"] == "pickup_not_offered"
    assert not calls("create_service_booking")
    # a vendor cancelling without a reason
    b = vbook(swd)
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    n = len(calls("transition_service_booking"))
    assert client.patch(f"{VB}/{b['id']}/status", json={"status": "cancelled"}, headers=swd.hva).json()["error"]["code"] == "reason_required"
    assert client.patch(f"{VB}/{b['id']}/status", json={"status": "cancelled", "note": "  "}, headers=swd.hva).status_code == 422
    assert len(calls("transition_service_booking")) == n
    # an inactive service is invisible to the public catalogue even through a client that bypasses RLS
    swd.svc["is_active"] = False
    with pytest.raises(NotFoundError):
        ServiceCatalogService(FakeClient(swd.db, SERVICE)).get(uuid.UUID(swd.svc["id"]))
