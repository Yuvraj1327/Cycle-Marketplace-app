import uuid

C = "/api/v1/categories"
A = "/api/v1/admin/categories"


def test_public_list_only_active_with_counts_and_order(client, db):
    v, vendor = db.add_approved_vendor()
    new = db.add_category("new_cycle", "New Cycles", sort_order=1)
    used = db.add_category("used_cycle", "Used Cycles", sort_order=2)
    db.add_category("spare_part", "Hidden", is_active=False, sort_order=0)
    db.add_product(vendor["id"], new); db.add_product(vendor["id"], new)
    db.add_product(vendor["id"], new, approval_status="pending")     # not public => not counted
    db.add_product(vendor["id"], used, is_active=False)
    r = client.get(C)
    assert r.status_code == 200 and r.headers["cache-control"] == "public, max-age=60"
    body = r.json()
    assert [c["name"] for c in body] == ["New Cycles", "Used Cycles"]
    assert [c["product_count"] for c in body] == [2, 0]
    assert client.get(C + "?include_counts=false").json()[0]["product_count"] is None


def test_filters_and_get_one(client, db):
    parent = db.add_category("spare_part", "Spare Parts")
    child = db.add_category("spare_part", "Brakes", parent_id=parent["id"])
    db.add_category("accessory", "Accessories")
    assert [c["name"] for c in client.get(C + "?kind=accessory").json()] == ["Accessories"]
    assert [c["name"] for c in client.get(C + f"?parent_id={parent['id']}").json()] == ["Brakes"]
    assert [c["name"] for c in client.get(C + "?root_only=true&kind=spare_part").json()] == ["Spare Parts"]
    assert client.get(f"{C}/{child['id']}").json()["slug"].startswith("brakes")
    assert client.get(f"{C}/{uuid.uuid4()}").status_code == 404
    assert client.get(C + "?kind=nonsense").status_code == 422


def test_inactive_category_is_404_publicly(client, db):
    c = db.add_category("accessory", "Old", is_active=False)
    assert client.get(f"{C}/{c['id']}").status_code == 404


def test_category_image_url(client, db):
    db.add_category("accessory", "Helmets", image_path="categories/helmets.jpg")
    assert client.get(C).json()[0]["image_url"].endswith("/storage/v1/object/public/banners/categories/helmets.jpg")


# ---------------- admin ----------------
def test_only_admin_manages_categories(client, db, auth):
    cust = db.add_profile(); vend, _ = db.add_approved_vendor()
    body = {"name": "Tyres", "kind": "spare_part"}
    assert client.post(A, json=body).status_code == 401
    for uid in (cust, vend):
        assert client.post(A, headers=auth(uid), json=body).status_code == 403
        assert client.get(A, headers=auth(uid)).status_code == 403
        assert client.put(f"{A}/{uuid.uuid4()}", headers=auth(uid), json={"name": "x"}).status_code == 403
        assert client.delete(f"{A}/{uuid.uuid4()}", headers=auth(uid)).status_code == 403
    assert db.tables.get("categories", []) == []


def test_admin_create_edit_deactivate(client, db, auth):
    h = auth(db.add_profile(role="admin"))
    r = client.post(A, headers=h, json={"name": "Tyres & Tubes", "kind": "spare_part", "description": "Rubber", "sort_order": 3})
    assert r.status_code == 201 and r.json()["slug"] == "tyres-tubes" and r.json()["is_active"] is True
    cid = r.json()["id"]
    assert client.post(A, headers=h, json={"name": "Tyres Tubes", "kind": "spare_part"}).json()["slug"] == "tyres-tubes-2"
    u = client.put(f"{A}/{cid}", headers=h, json={"name": "Tyres", "is_active": False, "description": None})
    assert u.status_code == 200 and u.json()["name"] == "Tyres" and u.json()["is_active"] is False and u.json()["description"] is None
    assert cid not in [c["id"] for c in client.get(C).json()]                      # hidden publicly
    assert cid in [c["id"] for c in client.get(A, headers=h).json()]               # still visible to admin
    assert client.put(f"{A}/{cid}", headers=h, json={}).status_code == 400
    assert client.put(f"{A}/{uuid.uuid4()}", headers=h, json={"name": "zz"}).status_code == 404


def test_admin_validation_and_slug_conflict(client, db, auth):
    h = auth(db.add_profile(role="admin"))
    assert client.post(A, headers=h, json={"name": "x", "kind": "spare_part"}).status_code == 422
    assert client.post(A, headers=h, json={"name": "Okay", "kind": "bogus"}).status_code == 422
    assert client.post(A, headers=h, json={"name": "Okay", "kind": "accessory", "image_path": "../evil.jpg"}).status_code == 422
    assert client.post(A, headers=h, json={"name": "Okay", "kind": "accessory", "slug": "okay"}).status_code == 201
    assert client.post(A, headers=h, json={"name": "Other", "kind": "accessory", "slug": "okay"}).status_code == 409


def test_subcategory_rules(client, db, auth):
    h = auth(db.add_profile(role="admin"))
    parent = client.post(A, headers=h, json={"name": "Spare Parts", "kind": "spare_part"}).json()
    ok = client.post(A, headers=h, json={"name": "Brakes", "kind": "spare_part", "parent_id": parent["id"]})
    assert ok.status_code == 201
    bad_kind = client.post(A, headers=h, json={"name": "Lights", "kind": "accessory", "parent_id": parent["id"]})
    assert bad_kind.status_code == 422 and bad_kind.json()["error"]["code"] == "invalid_parent"
    assert client.post(A, headers=h, json={"name": "Lost", "kind": "spare_part", "parent_id": str(uuid.uuid4())}).status_code == 422
    cycle = client.put(f"{A}/{parent['id']}", headers=h, json={"parent_id": ok.json()["id"]})
    assert cycle.status_code == 422
    assert client.put(f"{A}/{parent['id']}", headers=h, json={"kind": "accessory"}).status_code == 409   # has sub-categories


def test_delete_blocked_when_in_use_else_allowed(client, db, auth):
    h = auth(db.add_profile(role="admin"))
    _, vendor = db.add_approved_vendor()
    used = db.add_category("spare_part", "Used one")
    db.add_product(vendor["id"], used, approval_status="rejected", is_active=False)   # even an inactive product blocks
    r = client.delete(f"{A}/{used['id']}", headers=h)
    assert r.status_code == 409 and r.json()["error"]["code"] == "category_in_use"
    parent = db.add_category("accessory", "Parent"); db.add_category("accessory", "Kid", parent_id=parent["id"])
    assert client.delete(f"{A}/{parent['id']}", headers=h).json()["error"]["code"] == "category_has_children"
    free = db.add_category("accessory", "Unused")
    assert client.delete(f"{A}/{free['id']}", headers=h).status_code == 204
    assert client.delete(f"{A}/{free['id']}", headers=h).status_code == 404
