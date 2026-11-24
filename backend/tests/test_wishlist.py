import uuid

import pytest

W = "/api/v1/wishlist"


@pytest.fixture
def shop(db, auth):
    uid, v = db.add_approved_vendor("Alpha")
    cat = db.add_category("accessory", "Acc")
    cust = db.add_profile()
    return type("S", (), {"db": db, "v": v, "cat": cat, "h": auth(cust), "auth": auth,
                          "p": db.add_product(v["id"], cat, name="Helmet", price=999.0)})


def add(client, s, product, h=None):
    return client.post(f"{W}/items", headers=h or s.h, json={"product_id": product["id"]})


def test_requires_customer(client, db, auth, shop):
    assert client.get(W).status_code == 401
    for role in ("vendor", "admin"):
        assert client.get(W, headers=auth(db.add_profile(role=role))).status_code == 403


def test_add_view_remove(client, shop):
    r = add(client, shop, shop.p)
    assert r.status_code == 201 and r.json()["product"]["name"] == "Helmet" and r.json()["status"] == "ok"
    view = client.get(W, headers=shop.h).json()
    assert view["total"] == 1 and view["items"][0]["product"]["price"] == 999 and view["items"][0]["product"]["vendor"]["business_name"] == "Alpha"
    assert client.delete(f"{W}/items/{r.json()['id']}", headers=shop.h).status_code == 204
    assert client.get(W, headers=shop.h).json()["total"] == 0
    assert client.delete(f"{W}/items/{r.json()['id']}", headers=shop.h).status_code == 404


def test_duplicate_entries_are_prevented(client, shop):
    first = add(client, shop, shop.p)
    again = add(client, shop, shop.p)
    assert again.status_code == 200 and again.json()["id"] == first.json()["id"]
    assert client.get(W, headers=shop.h).json()["total"] == 1 and len(shop.db.tables["wishlist_items"]) == 1


def test_only_listed_products_can_be_saved(client, shop, db):
    for kw in ({"approval_status": "pending"}, {"is_active": False}):
        assert add(client, shop, db.add_product(shop.v["id"], shop.cat, **kw)).status_code == 404
    assert client.post(f"{W}/items", headers=shop.h, json={"product_id": str(uuid.uuid4())}).status_code == 404
    assert client.post(f"{W}/items", headers=shop.h, json={"product_id": "x"}).status_code == 422
    out = db.add_product(shop.v["id"], shop.cat, name="Sold Out", stock_quantity=0)
    r = add(client, shop, out)
    assert r.status_code == 201 and r.json()["status"] == "out_of_stock"          # saving for later is allowed


def test_item_that_gets_delisted_is_flagged(client, shop):
    add(client, shop, shop.p)
    shop.p["is_active"] = False
    item = client.get(W, headers=shop.h).json()["items"][0]
    assert item["status"] == "not_listed" and item["product"] is None


def test_wishlist_is_private(client, shop):
    other = shop.auth(shop.db.add_profile())
    mine = add(client, shop, shop.p).json()
    assert client.get(W, headers=other).json()["items"] == []
    assert client.delete(f"{W}/items/{mine['id']}", headers=other).status_code == 404
    assert client.get(W, headers=shop.h).json()["total"] == 1
    assert add(client, shop, shop.p, h=other).status_code == 201                       # same product, separate list
    assert client.get(W, headers=shop.h).json()["total"] == 1
    assert client.post(f"{W}/items", headers=other, json={"product_id": shop.p["id"], "wishlist_id": "x"}).status_code == 422
