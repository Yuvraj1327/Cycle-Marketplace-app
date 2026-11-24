import uuid

A = "/api/v1/addresses"
BODY = {"recipient_name": "Asha", "phone": "+919800000001", "address_line1": "12 MG Road", "city": "Pune",
        "state": "Maharashtra", "postal_code": "411001"}


def mk(client, h, **over):
    r = client.post(A, headers=h, json={**BODY, **over})
    assert r.status_code == 201, r.text
    return r.json()


def test_requires_auth_and_customer_role(client, db, auth):
    assert client.get(A).status_code == 401
    for role in ("vendor", "admin"):
        uid = db.add_profile(role=role)
        assert client.get(A, headers=auth(uid)).status_code == 403
        assert client.post(A, headers=auth(uid), json=BODY).status_code == 403


def test_first_address_is_default_second_is_not(client, db, auth):
    h = auth(db.add_profile())
    first, second = mk(client, h), mk(client, h, address_line1="2nd")
    assert first["is_default"] is True and second["is_default"] is False
    listing = client.get(A, headers=h).json()
    assert [x["id"] for x in listing][0] == first["id"] and len(listing) == 2


def test_create_as_default_moves_default(client, db, auth):
    h = auth(db.add_profile())
    first = mk(client, h)
    second = mk(client, h, address_line1="2nd", is_default=True)
    rows = {r["id"]: r["is_default"] for r in client.get(A, headers=h).json()}
    assert rows == {first["id"]: False, second["id"]: True}


def test_set_default_patch(client, db, auth):
    h = auth(db.add_profile())
    first, second = mk(client, h), mk(client, h, address_line1="2nd")
    r = client.patch(f"{A}/{second['id']}/default", headers=h)
    assert r.status_code == 200 and r.json()["is_default"] is True
    assert client.get(f"{A}/{first['id']}", headers=h).json()["is_default"] is False
    assert client.patch(f"{A}/{second['id']}/default", headers=h).status_code == 200   # idempotent


def test_get_update_delete_own(client, db, auth):
    h = auth(db.add_profile())
    a = mk(client, h)
    assert client.get(f"{A}/{a['id']}", headers=h).json()["city"] == "Pune"
    u = client.put(f"{A}/{a['id']}", headers=h, json={"city": "Mumbai", "landmark": "Near park"})
    assert u.status_code == 200 and u.json()["city"] == "Mumbai" and u.json()["address_line1"] == "12 MG Road"
    assert client.delete(f"{A}/{a['id']}", headers=h).status_code == 204
    assert client.get(f"{A}/{a['id']}", headers=h).status_code == 404


def test_ownership_other_customer_gets_404_and_nothing_changes(client, db, auth):
    ha, hb = auth(db.add_profile()), auth(db.add_profile())
    a = mk(client, ha)
    assert client.get(A, headers=hb).json() == []
    assert client.get(f"{A}/{a['id']}", headers=hb).status_code == 404
    assert client.put(f"{A}/{a['id']}", headers=hb, json={"city": "Hacked"}).status_code == 404
    assert client.patch(f"{A}/{a['id']}/default", headers=hb).status_code == 404
    assert client.delete(f"{A}/{a['id']}", headers=hb).status_code == 404
    still = client.get(f"{A}/{a['id']}", headers=ha).json()
    assert still["city"] == "Pune"


def test_cannot_create_address_for_someone_else(client, db, auth):
    other = db.add_profile(); h = auth(db.add_profile())
    assert client.post(A, headers=h, json={**BODY, "user_id": other}).status_code == 422
    assert db.tables.get("user_addresses", []) == []


def test_validation(client, db, auth):
    h = auth(db.add_profile())
    assert client.post(A, headers=h, json={**BODY, "postal_code": "123"}).status_code == 422
    assert client.post(A, headers=h, json={**BODY, "postal_code": "011001"}).status_code == 422   # PIN can't start with 0
    assert client.post(A, headers=h, json={**BODY, "phone": "abc"}).status_code == 422
    assert client.post(A, headers=h, json={**BODY, "address_type": "home"}).status_code == 422
    assert client.post(A, headers=h, json={k: v for k, v in BODY.items() if k != "city"}).status_code == 422
    assert client.post(A, headers=h, json={**BODY, "country": "UK", "postal_code": "SW1A 1AA"}).status_code == 201
    a = mk(client, h)
    assert client.put(f"{A}/{a['id']}", headers=h, json={}).status_code == 400
    assert client.put(f"{A}/{a['id']}", headers=h, json={"postal_code": "12"}).status_code == 422
    assert client.put(f"{A}/{a['id']}", headers=h, json={"is_default": True}).status_code == 422   # use PATCH
    assert client.get(f"{A}/not-a-uuid", headers=h).status_code == 422
    assert client.get(f"{A}/{uuid.uuid4()}", headers=h).status_code == 404
