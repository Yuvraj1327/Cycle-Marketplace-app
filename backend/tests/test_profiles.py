import pytest

P = "/api/v1/profiles/me"


def test_get_own_profile_only(client, db, auth):
    a, b = db.add_profile(full_name="Alice"), db.add_profile(full_name="Bob")
    r = client.get(P, headers=auth(a))
    assert r.status_code == 200 and r.json()["full_name"] == "Alice" and r.json()["id"] == a
    assert client.get(P, headers=auth(b)).json()["full_name"] == "Bob"
    assert client.get(P).status_code == 401


def test_update_changes_only_caller(client, db, auth):
    a, b = db.add_profile(), db.add_profile(full_name="Bob")
    r = client.put(P, headers=auth(a), json={"full_name": "  New Name "})
    assert r.status_code == 200 and r.json()["full_name"] == "New Name"
    assert client.get(P, headers=auth(b)).json()["full_name"] == "Bob"


@pytest.mark.parametrize("field,value", [("role", "admin"), ("role", "vendor"), ("status", "active"), ("email", "x@y.com"), ("id", "abc")])
def test_privileged_fields_rejected(client, db, auth, field, value):
    uid = db.add_profile()
    r = client.put(P, headers=auth(uid), json={field: value})
    assert r.status_code == 422 and r.json()["error"]["code"] == "validation_error"
    assert db.tables["profiles"][0]["role"] == "customer"


def test_validation(client, db, auth):
    uid = db.add_profile()
    assert client.put(P, headers=auth(uid), json={"phone": "12ab"}).status_code == 422
    assert client.put(P, headers=auth(uid), json={"full_name": ""}).status_code == 422
    assert client.put(P, headers=auth(uid), json={}).status_code == 400
    assert client.put(P, headers=auth(uid), json={"full_name": None}).status_code == 400   # NOT NULL column


def test_contact_phone_editable_when_not_an_auth_identifier(client, db, auth):
    uid = db.add_profile()
    assert client.put(P, headers=auth(uid), json={"phone": "+919800000001"}).json()["phone"] == "+919800000001"


def test_verified_auth_phone_cannot_be_changed_here(client, db, auth):
    uid = db.add_profile(phone="+919800000001")
    r = client.put(P, headers=auth(uid, extra={"phone": "919800000001"}), json={"phone": "+919800000002"})
    assert r.status_code == 403
    ok = client.put(P, headers=auth(uid, extra={"phone": "919800000001"}), json={"phone": "+919800000001", "full_name": "Same"})
    assert ok.status_code == 200


def test_duplicate_phone_is_conflict(client, db, auth):
    db.add_profile(phone="+919800000009"); uid = db.add_profile()
    assert client.put(P, headers=auth(uid), json={"phone": "+919800000009"}).status_code == 409


def test_avatar_must_be_in_own_folder(client, db, auth):
    uid, other = db.add_profile(), db.add_profile()
    assert client.put(P, headers=auth(uid), json={"avatar_path": f"{other}/a.jpg"}).status_code == 422
    assert client.put(P, headers=auth(uid), json={"avatar_path": f"{uid}/a.jpg"}).json()["avatar_path"] == f"{uid}/a.jpg"


def test_vendor_and_admin_can_use_own_profile(client, db, auth):
    for role in ("vendor", "admin"):
        uid = db.add_profile(role=role)
        assert client.get(P, headers=auth(uid)).json()["role"] == role


def test_preferences_are_saved_merged_and_returned(client, db, auth):
    uid = db.add_profile(preferences={})
    r = client.put(P, headers=auth(uid), json={"preferences": {"theme": "dark", "timezone": "Asia/Kolkata", "date_format": "DD/MM/YYYY"}})
    assert r.status_code == 200 and r.json()["preferences"] == {"theme": "dark", "timezone": "Asia/Kolkata", "date_format": "DD/MM/YYYY"}
    # a partial update changes only what was sent
    r = client.put(P, headers=auth(uid), json={"preferences": {"theme": "light"}})
    assert r.json()["preferences"]["theme"] == "light" and r.json()["preferences"]["timezone"] == "Asia/Kolkata"
    assert client.get(P, headers=auth(uid)).json()["preferences"]["theme"] == "light"


@pytest.mark.parametrize("prefs", [{"theme": "blue"}, {"currency": "INR"}, {"timezone": "Mars/Base"}, {"date_format": "YY"}, {"unknown": 1}, {}])
def test_invalid_preferences_rejected(client, db, auth, prefs):
    uid = db.add_profile(preferences={})
    assert client.put(P, headers=auth(uid), json={"preferences": prefs}).status_code in (400, 422)
