import uuid

import pytest

VP = "/api/v1/vendor/products"
PUB = "/api/v1/products"


@pytest.fixture
def v(db, auth):
    uid, vendor = db.add_approved_vendor("Alpha")
    cat = db.add_category("new_cycle", "New Cycles")
    spare = db.add_category("spare_part", "Spare Parts")
    used = db.add_category("used_cycle", "Used Cycles")
    return type("V", (), {"uid": uid, "vendor": vendor, "h": auth(uid), "cat": cat, "spare": spare, "used": used})


def body(cat, **kw):
    return {"category_id": cat["id"], "name": "City Bike 700C", "brand": "Hero", "model": "Sprint", "condition": "new", "price": 12500.5,
            "stock_quantity": 4, "specifications": {"frame": "Steel", "gears": 21, "tags": ["urban", "commuter"]}, **kw}


def test_create_enters_moderation_and_is_hidden_publicly(client, db, v):
    r = client.post(VP, headers=v.h, json=body(v.cat))
    assert r.status_code == 201
    p = r.json()
    assert p["approval_status"] == "pending" and p["moderation_status"] == "pending" and p["price"] == 12500.5
    assert p["product_type"] == "new_cycle" and p["vendor"]["id"] == v.vendor["id"] and p["specifications"]["gears"] == 21
    assert client.get(PUB).json()["total"] == 0
    assert client.get(f"{PUB}/{p['id']}").status_code == 404


def test_vendor_identity_and_approval_come_from_session_not_body(client, db, v):
    other_uid, other = db.add_approved_vendor("Other")
    for extra in ({"vendor_id": other["id"]}, {"approval_status": "approved"}, {"is_featured": True}, {"product_type": "accessory"},
                  {"reviewed_by": other_uid}, {"review_notes": "x"}):
        assert client.post(VP, headers=v.h, json=body(v.cat, **extra)).status_code == 422, extra
    assert db.tables.get("products", []) == []


def test_listing_approval_can_be_switched_off_by_platform_setting(client, db, v):
    db.rows("platform_settings").append({"key": "marketplace.require_listing_approval", "value": False})
    p = client.post(VP, headers=v.h, json=body(v.cat)).json()
    assert p["approval_status"] == "approved"
    assert client.get(f"{PUB}/{p['id']}").status_code == 200
    db.rows("platform_settings")[0]["value"] = True
    assert client.post(VP, headers=v.h, json=body(v.cat)).json()["approval_status"] == "pending"
    db.rows("platform_settings")[0]["value"] = "garbage"                       # malformed => safest default (moderation on)
    assert client.post(VP, headers=v.h, json=body(v.cat)).json()["approval_status"] == "pending"


def test_moderation_defaults_on_when_setting_missing(client, db, v):
    assert client.post(VP, headers=v.h, json=body(v.cat)).json()["approval_status"] == "pending"


def test_validation(client, db, v):
    bad = [{"price": -1}, {"price": 10_000_001}, {"price": 1.234}, {"stock_quantity": -1}, {"stock_quantity": 1_000_001}, {"name": "x"},
           {"condition": "refurbished"}, {"specifications": {"a": {"nested": "dict"}}}, {"specifications": {str(i): i for i in range(41)}},
           {"category_id": "nope"}]
    for over in bad:
        assert client.post(VP, headers=v.h, json=body(v.cat, **over)).status_code == 422, over
    r = client.post(VP, headers=v.h, json=body({"id": str(uuid.uuid4())}))
    assert r.status_code == 422 and r.json()["error"]["code"] == "invalid_category"
    inactive = db.add_category("accessory", "Off", is_active=False)
    assert client.post(VP, headers=v.h, json=body(inactive)).json()["error"]["code"] == "invalid_category"


def test_condition_must_match_cycle_category(client, db, v):
    r = client.post(VP, headers=v.h, json=body(v.used, condition="new"))
    assert r.status_code == 422 and r.json()["error"]["code"] == "invalid_condition"
    assert client.post(VP, headers=v.h, json=body(v.cat, condition="used")).status_code == 422
    assert client.post(VP, headers=v.h, json=body(v.used, condition="used")).status_code == 201
    assert client.post(VP, headers=v.h, json=body(v.spare, condition="used", name="Used Chain")).status_code == 201   # parts: either


def test_list_get_filters_only_own(client, db, v, auth):
    mine = client.post(VP, headers=v.h, json=body(v.cat)).json()
    client.post(VP, headers=v.h, json=body(v.cat, name="Second Bike"))
    ouid, other = db.add_approved_vendor("Other")
    db.add_product(other["id"], v.cat, name="Not Mine")
    r = client.get(VP, headers=v.h).json()
    assert r["total"] == 2 and "Not Mine" not in [i["name"] for i in r["items"]]
    assert client.get(f"{VP}?approval_status=approved", headers=v.h).json()["total"] == 0
    assert client.get(f"{VP}?q=second", headers=v.h).json()["total"] == 1
    assert client.get(f"{VP}/{mine['id']}", headers=v.h).json()["id"] == mine["id"]


def test_cross_vendor_access_is_404_and_changes_nothing(client, db, v, auth):
    ouid, other = db.add_approved_vendor("Other")
    theirs = db.add_product(other["id"], v.cat, name="Theirs", price=100.0, stock_quantity=9)
    path = f"{VP}/{theirs['id']}"
    assert client.get(path, headers=v.h).status_code == 404
    assert client.put(path, headers=v.h, json={**body(v.cat), "is_active": True}).status_code == 404
    assert client.patch(path, headers=v.h, json={"price": 1}).status_code == 404
    assert client.delete(path, headers=v.h).status_code == 404
    assert client.get(f"{path}/images", headers=v.h).status_code == 404
    still = next(p for p in db.tables["products"] if p["id"] == theirs["id"])
    assert (still["price"], still["stock_quantity"], still["name"]) == (100.0, 9, "Theirs")


def test_patch_price_stock_availability_and_deactivate(client, db, v):
    p = client.post(VP, headers=v.h, json=body(v.cat)).json()
    db.tables["products"][0]["approval_status"] = "approved"
    r = client.patch(f"{VP}/{p['id']}", headers=v.h, json={"price": 9999, "stock_quantity": 0})
    assert r.status_code == 200 and r.json()["price"] == 9999 and r.json()["stock_quantity"] == 0 and r.json()["approval_status"] == "approved"
    assert client.get(f"{PUB}/{p['id']}").json()["in_stock"] is False
    assert client.patch(f"{VP}/{p['id']}", headers=v.h, json={"stock_quantity": -3}).status_code == 422
    assert client.patch(f"{VP}/{p['id']}", headers=v.h, json={"is_available": False}).json()["is_available"] is False
    off = client.patch(f"{VP}/{p['id']}", headers=v.h, json={"is_active": False}).json()
    assert off["moderation_status"] == "inactive" and client.get(f"{PUB}/{p['id']}").status_code == 404
    assert client.patch(f"{VP}/{p['id']}", headers=v.h, json={"is_active": True}).json()["moderation_status"] == "approved"
    assert client.patch(f"{VP}/{p['id']}", headers=v.h, json={}).status_code == 400
    assert client.patch(f"{VP}/{p['id']}", headers=v.h, json={"name": None}).status_code == 400


def test_patch_cannot_touch_approval_fields(client, db, v):
    p = client.post(VP, headers=v.h, json=body(v.cat)).json()
    for field, val in [("approval_status", "approved"), ("is_featured", True), ("vendor_id", str(uuid.uuid4())), ("review_notes", "ok"), ("product_type", "accessory")]:
        assert client.patch(f"{VP}/{p['id']}", headers=v.h, json={field: val}).status_code == 422
    assert db.tables["products"][0]["approval_status"] == "pending" and db.tables["products"][0]["is_featured"] is False


def test_put_replaces_editable_fields(client, db, v):
    p = client.post(VP, headers=v.h, json=body(v.cat)).json()
    r = client.put(f"{VP}/{p['id']}", headers=v.h, json={"category_id": v.cat["id"], "name": "Renamed", "condition": "new", "price": 100, "stock_quantity": 1})
    assert r.status_code == 200 and r.json()["name"] == "Renamed" and r.json()["brand"] is None and r.json()["specifications"] == {}
    assert client.put(f"{VP}/{p['id']}", headers=v.h, json={"name": "partial only"}).status_code == 422


def test_category_change_updates_type_and_rechecks_condition(client, db, v):
    p = client.post(VP, headers=v.h, json=body(v.cat)).json()
    assert client.patch(f"{VP}/{p['id']}", headers=v.h, json={"category_id": v.used["id"]}).status_code == 422   # still 'new'
    r = client.patch(f"{VP}/{p['id']}", headers=v.h, json={"category_id": v.spare["id"]})
    assert r.status_code == 200 and r.json()["product_type"] == "spare_part"


def test_editing_a_rejected_listing_resubmits_it(client, db, v):
    p = client.post(VP, headers=v.h, json=body(v.cat)).json()
    row = db.tables["products"][0]; row["approval_status"] = "rejected"; row["review_notes"] = "Blurry photos"
    r = client.patch(f"{VP}/{p['id']}", headers=v.h, json={"description": "Now with better details"})
    assert r.json()["approval_status"] == "pending" and r.json()["review_notes"] is None


def test_delete_hard_when_never_ordered_else_deactivate(client, db, v, monkeypatch):
    import app.integrations.supabase as sb
    removed = []
    monkeypatch.setattr(sb, "delete_storage_object", lambda t, b, path: removed.append((b, path)))
    a = client.post(VP, headers=v.h, json=body(v.cat)).json()
    db.add_image(a["id"], f"{v.uid}/{a['id']}/1.jpg")
    r = client.delete(f"{VP}/{a['id']}", headers=v.h)
    assert r.json()["result"] == "deleted" and client.get(f"{VP}/{a['id']}", headers=v.h).status_code == 404
    assert removed == [("product-images", f"{v.uid}/{a['id']}/1.jpg")] and db.tables["product_images"] == []
    b = client.post(VP, headers=v.h, json=body(v.cat, name="Ordered Bike")).json()
    oid, void = str(uuid.uuid4()), str(uuid.uuid4())
    db.rows("orders").append({"id": oid, "customer_id": db.add_profile()})
    db.rows("vendor_orders").append({"id": void, "order_id": oid, "vendor_id": v.vendor["id"]})
    db.rows("order_items").append({"id": str(uuid.uuid4()), "product_id": b["id"], "vendor_order_id": void, "order_id": oid})
    r2 = client.delete(f"{VP}/{b['id']}", headers=v.h)
    assert r2.json()["result"] == "deactivated"
    kept = client.get(f"{VP}/{b['id']}", headers=v.h).json()
    assert kept["is_active"] is False and kept["is_available"] is False


@pytest.mark.parametrize("status", ["pending", "rejected", "suspended"])
def test_unapproved_vendors_cannot_manage_products(client, db, auth, status):
    uid = db.add_profile(role="vendor"); db.add_vendor(uid, status)
    h, cat = auth(uid), db.add_category("new_cycle")
    assert client.post(VP, headers=h, json=body(cat)).status_code == 403
    assert client.get(VP, headers=h).status_code == 403
    assert client.patch(f"{VP}/{uuid.uuid4()}", headers=h, json={"price": 1}).status_code == 403
    assert client.post(f"{VP}/{uuid.uuid4()}/images", headers=h, json={"storage_path": "a/b/c.jpg"}).status_code == 403


def test_non_vendors_and_anonymous_rejected(client, db, auth, v):
    cust, admin = db.add_profile(), db.add_profile(role="admin")
    assert client.get(VP).status_code == 401
    for uid in (cust, admin):
        assert client.get(VP, headers=auth(uid)).status_code == 403
        assert client.post(VP, headers=auth(uid), json=body(v.cat)).status_code == 403
    unregistered = db.add_profile(role="vendor")
    assert client.get(VP, headers=auth(unregistered)).json()["error"]["code"] == "vendor_not_registered"


def test_database_guard_blocks_vendor_approval_even_if_service_layer_were_bypassed(db, v):
    """Defence in depth: the (fake of the) guard trigger rejects a vendor-token write of approval fields."""
    from postgrest.exceptions import APIError

    from tests.conftest import FakeClient
    p = db.add_product(v.vendor["id"], v.cat, approval_status="pending")
    with pytest.raises(APIError):
        FakeClient(db, v.uid).table("products").update({"approval_status": "approved"}).eq("id", p["id"]).execute()
