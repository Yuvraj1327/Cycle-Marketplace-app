import uuid

import pytest

import app.services.product_image_service as svc

VP = "/api/v1/vendor/products"
PUB = "/api/v1/products"


@pytest.fixture
def env2(db, auth, monkeypatch):
    uid, vendor = db.add_approved_vendor()
    cat = db.add_category("new_cycle")
    prod = db.add_product(vendor["id"], cat)
    calls = {"head": [], "deleted": []}
    store = {"image/jpeg": (200, "image/jpeg", 1000)}
    monkeypatch.setattr(svc, "head_public_object", lambda b, p: calls["head"].append(p) or calls.get("override", store["image/jpeg"]))
    monkeypatch.setattr(svc, "delete_storage_object", lambda t, b, p: calls["deleted"].append((b, p)))
    return type("E", (), {"uid": uid, "h": auth(uid), "prod": prod, "calls": calls, "vendor": vendor, "cat": cat})


def path(e, name="front.jpg", pid=None):
    return f"{e.uid}/{pid or e.prod['id']}/{name}"


def reg(client, e, name="front.jpg", **kw):
    return client.post(f"{VP}/{e.prod['id']}/images", headers=e.h, json={"storage_path": path(e, name), **kw})


def test_register_first_image_becomes_primary_and_is_public(client, db, env2):
    r = reg(client, env2, alt_text="Front view")
    assert r.status_code == 201 and r.json()["is_primary"] is True and r.json()["url"].endswith(f"/product-images/{path(env2)}")
    assert env2.calls["head"] == [path(env2)]                               # existence was verified
    pub = client.get(f"{PUB}/{env2.prod['id']}").json()
    assert pub["primary_image_url"] == r.json()["url"] and len(pub["images"]) == 1


def test_second_image_not_primary_until_requested_and_ordering(client, db, env2):
    a = reg(client, env2, "a.jpg").json()
    b = reg(client, env2, "b.png").json()
    c = reg(client, env2, "c.webp").json()
    assert (a["is_primary"], b["is_primary"], c["is_primary"]) == (True, False, False)
    assert [a["sort_order"], b["sort_order"], c["sort_order"]] == [0, 1, 2]
    r = client.put(f"{VP}/{env2.prod['id']}/images/order", headers=env2.h, json={"image_ids": [c["id"], a["id"], b["id"]]})
    assert [i["id"] for i in r.json()] == [c["id"], a["id"], b["id"]]
    bad = client.put(f"{VP}/{env2.prod['id']}/images/order", headers=env2.h, json={"image_ids": [c["id"], a["id"]]})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "invalid_order"
    p = client.patch(f"{VP}/{env2.prod['id']}/images/{b['id']}", headers=env2.h, json={"is_primary": True})
    assert p.json()["is_primary"] is True
    prims = [i["is_primary"] for i in client.get(f"{VP}/{env2.prod['id']}/images", headers=env2.h).json()]
    assert prims.count(True) == 1
    assert client.patch(f"{VP}/{env2.prod['id']}/images/{b['id']}", headers=env2.h, json={"is_primary": False}).status_code == 409


def test_path_must_be_inside_own_product_folder(client, db, env2):
    other_uid, other_vendor = db.add_approved_vendor("Other")
    other_prod = db.add_product(other_vendor["id"], env2.cat)
    bads = [f"{other_uid}/{env2.prod['id']}/x.jpg",                 # someone else's user folder
            f"{env2.uid}/{other_prod['id']}/x.jpg",                 # another product
            f"{env2.uid}/{env2.prod['id']}/../x.jpg", f"{env2.uid}/{env2.prod['id']}/x.exe", f"{env2.uid}/{env2.prod['id']}/x.svg",
            f"{env2.uid}/x.jpg", f"{env2.uid}/{env2.prod['id']}/sub/x.jpg"]
    for p in bads:
        r = client.post(f"{VP}/{env2.prod['id']}/images", headers=env2.h, json={"storage_path": p})
        assert r.status_code == 422 and r.json()["error"]["code"] == "invalid_image_path", p
    assert env2.calls["head"] == [] and db.tables.get("product_images", []) == []


def test_cannot_attach_images_to_another_vendors_product(client, db, env2):
    other_uid, other_vendor = db.add_approved_vendor("Other")
    theirs = db.add_product(other_vendor["id"], env2.cat)
    r = client.post(f"{VP}/{theirs['id']}/images", headers=env2.h, json={"storage_path": f"{env2.uid}/{theirs['id']}/x.jpg"})
    assert r.status_code == 404


def test_file_must_exist_with_allowed_type_and_size(client, db, env2):
    env2.calls["override"] = None
    r = reg(client, env2)
    assert r.status_code == 422 and r.json()["error"]["code"] == "image_not_uploaded"
    env2.calls["override"] = (200, "application/pdf", 10)
    assert reg(client, env2).json()["error"]["code"] == "unsupported_image_type"
    env2.calls["override"] = (200, "image/png", 6 * 1024 * 1024)
    assert reg(client, env2).json()["error"]["code"] == "image_too_large"
    env2.calls["override"] = (200, "image/png", 1024)
    assert reg(client, env2).status_code == 201


def test_duplicate_path_and_image_limit(client, db, env2):
    assert reg(client, env2, "same.jpg").status_code == 201
    assert reg(client, env2, "same.jpg").status_code == 409
    for i in range(7):
        assert reg(client, env2, f"p{i}.jpg").status_code == 201
    r = reg(client, env2, "ninth.jpg")
    assert r.status_code == 409 and r.json()["error"]["code"] == "image_limit"


def test_delete_image_removes_file_and_promotes_next_primary(client, db, env2):
    a = reg(client, env2, "a.jpg").json(); b = reg(client, env2, "b.jpg").json()
    assert client.delete(f"{VP}/{env2.prod['id']}/images/{a['id']}", headers=env2.h).status_code == 204
    assert env2.calls["deleted"] == [("product-images", path(env2, "a.jpg"))]
    left = client.get(f"{VP}/{env2.prod['id']}/images", headers=env2.h).json()
    assert [i["id"] for i in left] == [b["id"]] and left[0]["is_primary"] is True
    assert client.delete(f"{VP}/{env2.prod['id']}/images/{a['id']}", headers=env2.h).status_code == 404


def test_other_vendor_cannot_delete_or_edit_images(client, db, env2, auth):
    img = reg(client, env2).json()
    other_uid, _ = db.add_approved_vendor("Other")
    h = auth(other_uid)
    assert client.delete(f"{VP}/{env2.prod['id']}/images/{img['id']}", headers=h).status_code == 404
    assert client.patch(f"{VP}/{env2.prod['id']}/images/{img['id']}", headers=h, json={"alt_text": "x"}).status_code == 404
    assert client.put(f"{VP}/{env2.prod['id']}/images/order", headers=h, json={"image_ids": [img["id"]]}).status_code == 404
    assert env2.calls["deleted"] == [] and len(db.tables["product_images"]) == 1


def test_image_validation_misc(client, db, env2):
    assert client.post(f"{VP}/{env2.prod['id']}/images", headers=env2.h, json={"storage_path": path(env2), "extra": 1}).status_code == 422
    assert client.put(f"{VP}/{env2.prod['id']}/images/order", headers=env2.h, json={"image_ids": []}).status_code == 422
    assert client.patch(f"{VP}/{env2.prod['id']}/images/{uuid.uuid4()}", headers=env2.h, json={"alt_text": "x"}).status_code == 404
