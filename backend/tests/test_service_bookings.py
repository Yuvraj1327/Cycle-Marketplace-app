import uuid

B = "/api/v1/service-bookings"
VB = "/api/v1/vendor/service-bookings"


def test_requires_customer_role(client, swd):
    body = {"service_id": swd.svc["id"], "issue_description": "Brakes squeal and the chain skips", "preferred_date": swd.day(3), "slot_start": "10:00"}
    assert client.post(B, json=body).status_code == 401
    for h in (swd.ha, swd.hva):
        assert client.post(B, json=body, headers=h).status_code == 403
        assert client.get(B, headers=h).status_code == 403


def test_create_booking_snapshots_price_from_database(client, swd):
    r = swd.book(cycle_brand="Hero", cycle_model="Sprint", cycle_details="Blue 26 inch hybrid")
    assert r.status_code == 201, r.text
    b = r.json()
    assert b["status"] == "pending" and b["booking_number"].startswith("BKG-") and b["service_name"] == "Full service" and b["vendor_name"] == "Alpha Cycles"
    assert b["cycle"] == {"brand": "Hero", "model": "Sprint", "details": "Blue 26 inch hybrid"} and b["can_cancel"] is True
    assert b["preferred"] == {"date": swd.day(3), "slot_start": "10:00", "slot_end": "11:00"}
    assert b["confirmed"] == {"date": None, "slot_start": None, "slot_end": None}                  # preferred != confirmed
    p = b["pricing"]
    assert (p["estimated_price"], p["additional_charges_total"], p["current_price"], p["total_current"]) == (499, 0, 499, 499) and b["estimated_duration_minutes"] == 120
    assert b["vendor"]["business_name"] == "Alpha Cycles" and b["pickup"] is None and b["service_category"]["name"] == "General Servicing"
    row = swd.db.tables["service_bookings"][0]
    assert row["customer_id"] == swd.cust and row["vendor_id"] == swd.va["id"]
    create_call = [prm for fn, prm in swd.db.sql.calls if fn == "create_service_booking"][0]["p"]
    assert "estimated_price" not in create_call and "vendor_id" not in create_call               # price and vendor are NOT supplied by the client path


def test_client_cannot_inject_identity_or_price(client, swd):
    for extra in ({"customer_id": swd.other}, {"vendor_id": swd.vb["id"]}, {"estimated_price": 1}, {"final_price": 1}, {"status": "accepted"}, {"confirmed_date": swd.day(3)}):
        assert swd.book(**extra).status_code == 422, extra
    assert not swd.db.tables.get("service_bookings")


def test_validation_errors(client, swd):
    assert swd.book(service={"id": str(uuid.uuid4())}).status_code == 404                                  # invalid service
    swd.svc["is_active"] = False
    assert swd.book().status_code == 404
    swd.svc["is_active"] = True
    swd.svc["is_available"] = False
    assert swd.book().json()["error"]["code"] in ("service_unavailable",)
    swd.svc["is_available"] = True
    for bad in ({"issue_description": "short"}, {"slot_start": "9am"}, {"slot_start": "25:00"}, {"preferred_date": "2026-99-01"}, {"cycle_brand": "x" * 101}):
        assert swd.book(**bad).status_code == 422, bad
    r = swd.book(slot_start="09:30")
    assert r.status_code == 422 and r.json()["error"]["code"] == "invalid_slot" and "09:00" in r.json()["error"]["details"][0]["slots"]
    assert swd.book(slot_start="19:00").json()["error"]["code"] == "invalid_slot"                           # after closing
    assert swd.book(preferred_date=swd.day(-1)).json()["error"]["code"] == "slot_unavailable"               # date in the past
    assert swd.book(preferred_date=swd.day(400)).json()["error"]["code"] == "slot_unavailable"
    swd.va["operating_hours"] = {}
    assert swd.book().json()["error"]["code"] == "slot_unavailable"
    swd.va["operating_hours"] = {k: {"open": "09:00", "close": "18:00"} for k in ("mon", "tue", "wed", "thu", "fri", "sat", "sun")}
    assert not swd.db.tables.get("service_bookings")


def test_suspended_provider_cannot_be_booked(client, swd):
    swd.va["verification_status"] = "suspended"
    assert swd.book().status_code == 404


def test_duplicate_open_booking_prevented_but_different_slot_ok(client, swd):
    assert swd.book().status_code == 201
    dup = swd.book()
    assert dup.status_code == 409 and dup.json()["error"]["code"] == "duplicate_booking"
    assert swd.book(slot_start="11:00").status_code == 201
    assert swd.book(headers=swd.hother).status_code == 201                                                  # another customer, same slot (pending does not block)
    assert len(swd.db.tables["service_bookings"]) == 3


def test_pickup_and_dropoff_booking(client, swd):
    swd.setting("services.pickup_charge", 40); swd.setting("services.dropoff_charge", 30)
    r = swd.book(**swd.pickup_body(pickup_instructions="Gate B, call on arrival"))
    assert r.status_code == 201, r.text
    b = r.json()
    p = b["pickup"]
    assert p["pickup_stage"] == "requested" and p["delivery_stage"] == "requested" and p["pickup_status"] == "pending"
    assert p["pickup_address"]["city"] == "Pune" and p["dropoff_address"]["address_line1"] == "1 MG Rd" and p["customer_instructions"] == "Gate B, call on arrival"
    assert (p["pickup_charge"], p["dropoff_charge"]) == (40, 30)
    assert b["pricing"]["total_estimated"] == 499 + 70 and b["pricing"]["logistics_charges_configured"] is True


def test_unconfigured_logistics_charges_are_explicit_not_invented(client, swd):
    b = swd.book(**swd.pickup_body()).json()
    assert (b["pickup"]["pickup_charge"], b["pickup"]["dropoff_charge"]) == (0, 0) and b["pricing"]["logistics_charges_configured"] is False
    swd.setting("services.pickup_charge", 25)
    again = client.get(f"{B}/{b['id']}", headers=swd.h).json()
    assert again["pricing"]["logistics_charges_configured"] is False and again["pickup"]["pickup_charge"] == 0       # snapshot never silently changes


def test_pickup_address_rules(client, swd):
    other_addr = swd.address(swd.other)
    assert swd.book(**swd.pickup_body(pickup_address_id=other_addr["id"])).json()["error"]["code"] == "invalid_address"           # someone else's
    assert swd.book(**swd.pickup_body(pickup_address_id=str(uuid.uuid4()))).json()["error"]["code"] == "invalid_address"
    delivery_only = swd.address(swd.cust, kind="delivery")
    assert swd.book(**swd.pickup_body(pickup_address_id=delivery_only["id"])).json()["error"]["code"] == "invalid_address"       # not a pickup address
    pickup_only = swd.address(swd.cust, kind="pickup")
    assert swd.book(**swd.pickup_body(dropoff_address_id=pickup_only["id"])).json()["error"]["code"] == "invalid_address"         # not a drop-off address
    far = swd.address(swd.cust, postal="560001")
    r = swd.book(**swd.pickup_body(pickup_address_id=far["id"]))
    assert r.status_code == 422 and r.json()["error"]["code"] == "outside_service_area"
    assert swd.book(**{"needs_pickup_dropoff": True}).status_code == 422                                                       # address required
    assert swd.book(pickup_address_id=swd.addr["id"]).status_code == 422                                                       # address without pickup flag
    assert swd.book(service=swd.svc_b, **swd.pickup_body()).json()["error"]["code"] == "pickup_not_offered"
    assert not swd.db.tables.get("service_bookings")


def test_dropoff_defaults_to_pickup_and_can_differ(client, swd):
    other = swd.address(swd.cust, kind="delivery", postal="411002")
    b = swd.book(**swd.pickup_body(dropoff_address_id=other["id"])).json()
    assert b["pickup"]["dropoff_address"]["postal_code"] == "411002" and b["pickup"]["pickup_address"]["postal_code"] == "411001"


def test_ownership_isolation(client, swd):
    b = swd.book().json()
    assert client.get(B, headers=swd.hother).json()["total"] == 0
    for call in (lambda: client.get(f"{B}/{b['id']}", headers=swd.hother), lambda: client.get(f"{B}/{b['id']}/tracking", headers=swd.hother),
                 lambda: client.post(f"{B}/{b['id']}/cancel", json={"reason": "not mine to cancel"}, headers=swd.hother),
                 lambda: client.post(f"{B}/{b['id']}/images", json={"storage_path": f"{swd.other}/{b['id']}/a.jpg"}, headers=swd.hother)):
        assert call().status_code == 404
    assert client.get(f"{B}/{uuid.uuid4()}", headers=swd.h).status_code == 404 and client.get(f"{B}/nope", headers=swd.h).status_code == 422
    assert swd.db.tables["service_bookings"][0]["status"] == "pending"


def test_listing_filter_and_history_survive_vendor_changes(client, swd):
    a = swd.book().json(); swd.book(slot_start="11:00")
    client.post(f"{VB}/{a['id']}/accept", headers=swd.hva)
    assert client.get(B, headers=swd.h).json()["total"] == 2
    assert [x["id"] for x in client.get(B + "?status=accepted", headers=swd.h).json()["items"]] == [a["id"]]
    assert client.get(B + "?status=bogus", headers=swd.h).status_code == 422
    swd.va["business_name"] = "Renamed Shop"; swd.svc["name"] = "Renamed"
    d = client.get(f"{B}/{a['id']}", headers=swd.h).json()
    assert d["service_name"] == "Full service" and d["vendor_name"] == "Alpha Cycles"


def test_tracking_shows_stored_history_and_pickup_stages(client, swd):
    b = swd.book(**swd.pickup_body()).json()
    for step in ("accept",):
        client.post(f"{VB}/{b['id']}/{step}", headers=swd.hva)
    client.patch(f"{VB}/{b['id']}/status", json={"status": "picked_up", "note": "collected"}, headers=swd.hva)
    t = client.get(f"{B}/{b['id']}/tracking", headers=swd.h).json()
    assert t["status"] == "picked_up" and [e["to_status"] for e in t["timeline"]] == ["pending", "accepted", "picked_up"] and t["timeline"][-1]["note"] == "collected"
    assert t["pickup"]["pickup_stage"] == "picked_up" and t["pickup"]["delivery_stage"] == "requested" and t["confirmed"]["date"] == swd.day(3)


# ---------------- cancel
def test_customer_cancel_rules(client, swd):
    b = swd.book(**swd.pickup_body()).json()
    assert client.post(f"{B}/{b['id']}/cancel", json={"reason": "x"}, headers=swd.h).status_code == 422
    r = client.post(f"{B}/{b['id']}/cancel", json={"reason": "Plans changed, sorry"}, headers=swd.h)
    d = r.json()
    assert r.status_code == 200 and d["status"] == "cancelled" and d["cancellation_reason"] == "Plans changed, sorry" and d["can_cancel"] is False
    assert d["pickup"]["pickup_stage"] == "cancelled" and d["pickup"]["delivery_stage"] == "cancelled"
    assert client.post(f"{B}/{b['id']}/cancel", json={"reason": "again please"}, headers=swd.h).json()["error"]["code"] == "invalid_transition"
    assert swd.book(**swd.pickup_body()).status_code == 201                                  # the slot can be booked again after cancelling


def test_cannot_cancel_once_work_started(client, swd):
    b = swd.book().json()
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    client.patch(f"{VB}/{b['id']}/status", json={"status": "in_service"}, headers=swd.hva)
    r = client.post(f"{B}/{b['id']}/cancel", json={"reason": "give it back now"}, headers=swd.h)
    assert r.status_code == 409 and swd.db.tables["service_bookings"][0]["status"] == "in_service"


def test_accepted_booking_can_be_cancelled_and_releases_the_slot(client, swd):
    b = swd.book().json()
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    assert client.post(f"{B}/{b['id']}/cancel", json={"reason": "cannot make it"}, headers=swd.h).json()["status"] == "cancelled"
    slot = next(s for s in client.get(f"/api/v1/services/{swd.svc['id']}/availability?date={swd.day(3)}").json()["slots"] if s["start"] == "10:00")
    assert slot["available"] is True and swd.db.tables["service_bookings"][0]["confirmed_date"] is None


# ---------------- images
def path(swd, bid, name="front.jpg"):
    return f"{swd.cust}/{bid}/{name}"


def test_image_registration_and_signed_urls(client, swd):
    b = swd.book().json()
    p = path(swd, b["id"])
    assert client.post(f"{B}/{b['id']}/images", json={"storage_path": p}, headers=swd.h).json()["error"]["code"] == "image_not_uploaded"
    swd.storage["uploaded"].add(p)
    r = client.post(f"{B}/{b['id']}/images", json={"storage_path": p}, headers=swd.h)
    assert r.status_code == 201 and r.json()["storage_path"] == p
    d = client.get(f"{B}/{b['id']}", headers=swd.h).json()
    assert d["images"][0]["url"].startswith("https://signed.example/service-images/") and d["images"][0]["storage_path"] == p
    assert client.post(f"{B}/{b['id']}/images", json={"storage_path": p}, headers=swd.h).json()["error"]["code"] == "duplicate_image"
    assert client.delete(f"{B}/{b['id']}/images/{r.json()['id']}", headers=swd.h).status_code == 204 and swd.storage["deleted"] == [p]
    assert client.get(f"{B}/{b['id']}", headers=swd.h).json()["images"] == []


def test_image_path_type_size_and_limits(client, swd):
    b = swd.book().json()
    for bad in (f"{swd.other}/{b['id']}/a.jpg", f"{swd.cust}/{uuid.uuid4()}/a.jpg", f"{swd.cust}/{b['id']}/../a.jpg", f"{swd.cust}/{b['id']}/a.exe",
                f"{swd.cust}/{b['id']}/sub/a.jpg", f"{swd.cust}/a.jpg"):
        r = client.post(f"{B}/{b['id']}/images", json={"storage_path": bad}, headers=swd.h)
        assert r.status_code == 422 and r.json()["error"]["code"] == "invalid_image_path", bad
    p = path(swd, b["id"], "x.png"); swd.storage["uploaded"].add(p)
    swd.storage["type"] = "application/pdf"
    assert client.post(f"{B}/{b['id']}/images", json={"storage_path": p}, headers=swd.h).json()["error"]["code"] == "unsupported_image_type"
    swd.storage.update(type="image/png", size=6 * 1024 * 1024)
    assert client.post(f"{B}/{b['id']}/images", json={"storage_path": p}, headers=swd.h).json()["error"]["code"] == "image_too_large"
    swd.storage["size"] = 1000
    for i in range(5):
        q = path(swd, b["id"], f"p{i}.jpg"); swd.storage["uploaded"].add(q)
        assert client.post(f"{B}/{b['id']}/images", json={"storage_path": q}, headers=swd.h).status_code == 201
    extra = path(swd, b["id"], "p9.jpg"); swd.storage["uploaded"].add(extra)
    assert client.post(f"{B}/{b['id']}/images", json={"storage_path": extra}, headers=swd.h).json()["error"]["code"] == "image_limit"


def test_images_are_locked_after_the_provider_responds(client, swd):
    b = swd.book().json()
    p = path(swd, b["id"]); swd.storage["uploaded"].add(p)
    img = client.post(f"{B}/{b['id']}/images", json={"storage_path": p}, headers=swd.h).json()
    client.post(f"{VB}/{b['id']}/accept", headers=swd.hva)
    q = path(swd, b["id"], "late.jpg"); swd.storage["uploaded"].add(q)
    assert client.post(f"{B}/{b['id']}/images", json={"storage_path": q}, headers=swd.h).json()["error"]["code"] == "images_locked"
    assert client.delete(f"{B}/{b['id']}/images/{img['id']}", headers=swd.h).json()["error"]["code"] == "images_locked"


def test_vendor_and_admin_get_signed_urls_but_other_vendor_cannot_see_booking(client, swd):
    b = swd.book().json()
    p = path(swd, b["id"]); swd.storage["uploaded"].add(p)
    client.post(f"{B}/{b['id']}/images", json={"storage_path": p}, headers=swd.h)
    assert client.get(f"{VB}/{b['id']}", headers=swd.hva).json()["images"][0]["url"].startswith("https://signed.example/")
    assert client.get(f"/api/v1/admin/service-bookings/{b['id']}", headers=swd.ha).json()["images"][0]["storage_path"] == p
    assert client.get(f"{VB}/{b['id']}", headers=swd.hvb).status_code == 404


# ---------------- support tickets (complaints / disputes)
def test_support_tickets_owner_only_and_linked_to_own_records(client, swd):
    b = swd.book().json()
    T = "/api/v1/support-tickets"
    body = {"type": "complaint", "subject": "Brake still squeals", "description": "The repair did not fix the noise at all.", "service_booking_id": b["id"]}
    r = client.post(T, json=body, headers=swd.h)
    assert r.status_code == 201 and r.json()["status"] == "open" and r.json()["ticket_number"].startswith("TKT-")
    assert client.post(T, json=body, headers=swd.hother).json()["error"]["code"] == "invalid_reference"          # not their booking
    assert client.post(T, json={**body, "order_id": str(uuid.uuid4())}, headers=swd.h).status_code == 422          # both links
    assert client.post(T, json={**body, "service_booking_id": None, "order_id": str(uuid.uuid4())}, headers=swd.h).json()["error"]["code"] == "invalid_reference"
    assert client.get(T, headers=swd.h).json()["total"] == 1 and client.get(T, headers=swd.hother).json()["total"] == 0
    assert client.get(f"{T}/{r.json()['id']}", headers=swd.hother).status_code == 404
    assert client.post(T, json=body, headers=swd.hva).status_code == 403
