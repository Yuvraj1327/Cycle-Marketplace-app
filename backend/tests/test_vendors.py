V = "/api/v1/vendors"
APP = {"business_name": "Spoke & Co", "business_types": ["bicycle_shop", "service_provider"], "address_line1": "5 Cycle St",
       "city": "Pune", "state": "Maharashtra", "postal_code": "411001", "contact_phone": "+919800000001",
       "operating_hours": {"mon": {"open": "09:00", "close": "18:00"}, "sun": {"closed": True}},
       "service_area_postal_codes": ["411001", "411002"], "service_radius_km": 10, "pickup_available": True}


def vendor(db, auth, **kw):
    uid = db.add_profile(role="vendor", **kw)
    return uid, auth(uid)


def test_registration_creates_pending_application(client, db, auth):
    uid, h = vendor(db, auth)
    r = client.post(f"{V}/register", headers=h, json=APP)
    assert r.status_code == 201
    body = r.json()
    assert body["verification_status"] == "pending" and body["pickup_available"] is True
    assert "review_notes" not in body and "reviewed_by" not in body and "user_id" not in body
    assert db.tables["vendor_profiles"][0]["user_id"] == uid
    st = client.get(f"{V}/me/status", headers=h).json()
    assert st["verification_status"] == "pending" and st["can_operate"] is False


def test_cannot_self_approve_at_registration_or_later(client, db, auth):
    _, h = vendor(db, auth)
    for field, value in [("verification_status", "approved"), ("reviewed_by", "x"), ("rejection_reason", "x"), ("user_id", "x")]:
        assert client.post(f"{V}/register", headers=h, json={**APP, field: value}).status_code == 422
    assert client.post(f"{V}/register", headers=h, json=APP).status_code == 201
    for field, value in [("verification_status", "approved"), ("review_notes", "ok"), ("reviewed_at", "2026-01-01T00:00:00Z")]:
        assert client.put(f"{V}/me", headers=h, json={field: value}).status_code == 422
    assert client.get(f"{V}/me", headers=h).json()["verification_status"] == "pending"


def test_only_vendor_role_can_register(client, db, auth):
    for role in ("customer", "admin"):
        uid = db.add_profile(role=role)
        assert client.post(f"{V}/register", headers=auth(uid), json=APP).status_code == 403
        assert client.get(f"{V}/me", headers=auth(uid)).status_code == 403
    assert client.post(f"{V}/register", json=APP).status_code == 401
    assert db.tables.get("vendor_profiles", []) == []


def test_duplicate_application_conflict(client, db, auth):
    _, h = vendor(db, auth)
    assert client.post(f"{V}/register", headers=h, json=APP).status_code == 201
    assert client.post(f"{V}/register", headers=h, json=APP).status_code == 409
    assert len(db.tables["vendor_profiles"]) == 1


def test_me_before_registration_is_404(client, db, auth):
    _, h = vendor(db, auth)
    assert client.get(f"{V}/me", headers=h).status_code == 404
    assert client.get(f"{V}/me/status", headers=h).status_code == 404
    assert client.put(f"{V}/me", headers=h, json={"city": "x"}).status_code == 404


def test_update_business_info(client, db, auth):
    _, h = vendor(db, auth)
    client.post(f"{V}/register", headers=h, json=APP)
    r = client.put(f"{V}/me", headers=h, json={"business_name": "New Name", "pickup_available": False, "description": None})
    assert r.status_code == 200 and r.json()["business_name"] == "New Name" and r.json()["pickup_available"] is False
    assert r.json()["city"] == "Pune"
    assert client.put(f"{V}/me", headers=h, json={}).status_code == 400
    assert client.put(f"{V}/me", headers=h, json={"business_name": None}).status_code == 400


def test_vendors_only_see_their_own_profile(client, db, auth):
    _, h1 = vendor(db, auth); _, h2 = vendor(db, auth)
    client.post(f"{V}/register", headers=h1, json=APP)
    client.post(f"{V}/register", headers=h2, json={**APP, "business_name": "Other Shop"})
    assert client.get(f"{V}/me", headers=h1).json()["business_name"] == "Spoke & Co"
    assert client.get(f"{V}/me", headers=h2).json()["business_name"] == "Other Shop"
    client.put(f"{V}/me", headers=h2, json={"business_name": "Changed"})
    assert client.get(f"{V}/me", headers=h1).json()["business_name"] == "Spoke & Co"


def test_approved_status_reflected_and_suspended_blocked(client, db, auth):
    uid, h = vendor(db, auth)
    row = db.add_vendor(uid, "approved")
    assert client.get(f"{V}/me/status", headers=h).json()["can_operate"] is True
    row["verification_status"] = "suspended"
    assert client.get(f"{V}/me", headers=h).status_code == 200            # may still view
    r = client.put(f"{V}/me", headers=h, json={"city": "Goa"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "vendor_suspended"
    row["verification_status"] = "rejected"; row["rejection_reason"] = "Incomplete documents"
    st = client.get(f"{V}/me/status", headers=h).json()
    assert st["can_operate"] is False and st["rejection_reason"] == "Incomplete documents"
    assert client.put(f"{V}/me", headers=h, json={"city": "Goa"}).status_code == 200   # may fix and resubmit info


def test_inactive_vendor_account_blocked(client, db, auth):
    _, h = vendor(db, auth, status="restricted")
    assert client.post(f"{V}/register", headers=h, json=APP).status_code == 403


def test_validation(client, db, auth):
    uid, h = vendor(db, auth)
    bad = [
        {"business_types": []}, {"business_types": ["bank"]}, {"business_types": ["bicycle_shop", "bicycle_shop"]},
        {"contact_phone": "x"}, {"contact_email": "not-an-email"}, {"postal_code": "!"}, {"business_name": "a"},
        {"operating_hours": {"funday": {"open": "09:00", "close": "10:00"}}},
        {"operating_hours": {"mon": {"open": "18:00", "close": "09:00"}}},
        {"operating_hours": {"mon": {"open": "9am", "close": "5pm"}}},
        {"service_radius_km": -1}, {"shop_image_paths": ["a"] * 11},
    ]
    for over in bad:
        assert client.post(f"{V}/register", headers=h, json={**APP, **over}).status_code == 422, over
    r = client.post(f"{V}/register", headers=h, json={**APP, "shop_image_paths": ["someone-else/x.jpg"]})
    assert r.status_code == 422
    assert client.post(f"{V}/register", headers=h, json={**APP, "shop_image_paths": [f"{uid}/shop.jpg"]}).status_code == 201
