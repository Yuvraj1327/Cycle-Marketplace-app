import uuid

import pytest

CART = "/api/v1/cart"


@pytest.fixture
def shop(db, auth):
    uid1, v1 = db.add_approved_vendor("Alpha")
    uid2, v2 = db.add_approved_vendor("Beta")
    cat = db.add_category("new_cycle")
    parts = db.add_category("spare_part", "Parts")
    bike = db.add_product(v1["id"], cat, name="Bike", price=10000.0, stock_quantity=5)
    pads = db.add_product(v2["id"], parts, name="Pads", price=250.5, stock_quantity=10)
    cust = db.add_profile()
    return type("S", (), {"db": db, "bike": bike, "pads": pads, "cust": cust, "h": auth(cust), "v1": v1, "v2": v2, "cat": cat})


def add(client, s, product, qty=1, h=None):
    return client.post(f"{CART}/items", headers=h or s.h, json={"product_id": product["id"], "quantity": qty})


def test_cart_requires_customer_role(client, db, auth, shop):
    assert client.get(CART).status_code == 401
    for uid in (db.add_profile(role="vendor"), db.add_profile(role="admin")):
        assert client.get(CART, headers=auth(uid)).status_code == 403
        assert add(client, shop, shop.bike, h=auth(uid)).status_code == 403


def test_empty_cart_created_on_first_view(client, shop):
    r = client.get(CART, headers=shop.h).json()
    assert r["items"] == [] and r["summary"]["subtotal"] == 0 and r["summary"]["total_quantity"] == 0
    assert len(shop.db.tables["carts"]) == 1 and client.get(CART, headers=shop.h).json()["id"] == r["id"]   # not duplicated


def test_add_update_remove_clear_and_totals(client, shop):
    r = add(client, shop, shop.bike, 2)
    assert r.status_code == 201
    r = add(client, shop, shop.pads, 3).json()
    s = r["summary"]
    assert s["distinct_items"] == 2 and s["total_quantity"] == 5 and s["subtotal"] == 20000 + 751.5 and s["multi_vendor"] is True
    assert {g["business_name"]: g["subtotal"] for g in r["vendors"]} == {"Alpha": 20000.0, "Beta": 751.5}
    item = next(i for i in r["items"] if i["product"]["name"] == "Bike")
    assert item["unit_price"] == 10000 and item["line_total"] == 20000 and item["status"] == "ok" and item["product"]["vendor"]["business_name"] == "Alpha"
    up = client.put(f"{CART}/items/{item['id']}", headers=shop.h, json={"quantity": 1}).json()
    assert up["summary"]["subtotal"] == 10000 + 751.5
    rm = client.delete(f"{CART}/items/{item['id']}", headers=shop.h).json()
    assert [i["product"]["name"] for i in rm["items"]] == ["Pads"] and rm["summary"]["multi_vendor"] is False
    assert client.delete(f"{CART}/items/{item['id']}", headers=shop.h).status_code == 404
    cleared = client.delete(f"{CART}/clear", headers=shop.h).json()
    assert cleared["items"] == [] and cleared["summary"]["total_quantity"] == 0


def test_adding_same_product_merges_quantity(client, shop):
    assert add(client, shop, shop.bike, 2).status_code == 201
    r = add(client, shop, shop.bike, 1)
    assert r.status_code == 200 and r.json()["items"][0]["quantity"] == 3 and len(r.json()["items"]) == 1


def test_stock_is_validated_but_never_changed(client, shop):
    assert add(client, shop, shop.bike, 6).json()["error"]["code"] == "insufficient_stock"
    assert add(client, shop, shop.bike, 5).status_code == 201
    assert add(client, shop, shop.bike, 1).json()["error"]["code"] == "insufficient_stock"      # 5 + 1 > 5
    shop.bike["stock_quantity"] = 0
    assert add(client, shop, shop.pads, 1).status_code == 201
    shop.db.add_product(shop.v1["id"], shop.cat, name="Empty", stock_quantity=0)
    empty = shop.db.tables["products"][-1]
    assert add(client, shop, empty).json()["error"]["code"] == "out_of_stock"
    assert shop.pads["stock_quantity"] == 10                                    # nothing was reserved/deducted
    assert next(p for p in shop.db.tables["products"] if p["name"] == "Pads")["stock_quantity"] == 10


def test_unavailable_and_unlisted_products_cannot_be_added(client, shop, db):
    off = db.add_product(shop.v1["id"], shop.cat, name="Off", is_available=False)
    assert add(client, shop, off).json()["error"]["code"] == "product_unavailable"
    for kw in ({"approval_status": "pending"}, {"approval_status": "rejected"}, {"is_active": False}):
        assert add(client, shop, db.add_product(shop.v1["id"], shop.cat, **kw)).status_code == 404
    assert client.post(f"{CART}/items", headers=shop.h, json={"product_id": str(uuid.uuid4())}).status_code == 404


@pytest.mark.parametrize("qty", [0, -1, 101, "x", 1.5])
def test_invalid_quantities(client, shop, qty):
    assert client.post(f"{CART}/items", headers=shop.h, json={"product_id": shop.bike["id"], "quantity": qty}).status_code == 422
    assert not shop.db.tables.get("cart_items")


def test_update_quantity_validation(client, shop):
    item = add(client, shop, shop.bike, 1).json()["items"][0]
    for bad in (0, 101, -2):
        assert client.put(f"{CART}/items/{item['id']}", headers=shop.h, json={"quantity": bad}).status_code == 422
    assert client.put(f"{CART}/items/{item['id']}", headers=shop.h, json={"quantity": 6}).json()["error"]["code"] == "insufficient_stock"
    assert client.put(f"{CART}/items/{uuid.uuid4()}", headers=shop.h, json={"quantity": 1}).status_code == 404
    assert client.put(f"{CART}/items/{item['id']}", headers=shop.h, json={"quantity": 2, "product_id": "x"}).status_code == 422


def test_price_change_is_flagged_and_acknowledged(client, shop):
    item = add(client, shop, shop.bike, 1).json()["items"][0]
    shop.bike["price"] = 12000.0
    r = client.get(CART, headers=shop.h).json()
    it = r["items"][0]
    assert it["price_changed"] is True and it["previous_price"] == 10000 and it["unit_price"] == 12000 and r["summary"]["subtotal"] == 12000
    assert r["summary"]["has_price_changes"] is True
    ack = client.put(f"{CART}/items/{item['id']}", headers=shop.h, json={"quantity": 1}).json()
    assert ack["items"][0]["price_changed"] is False and ack["summary"]["has_price_changes"] is False


def test_products_that_become_unavailable_are_flagged_not_charged(client, shop):
    add(client, shop, shop.bike, 2); add(client, shop, shop.pads, 1)
    shop.bike["approval_status"] = "rejected"             # delisted after being added
    shop.pads["stock_quantity"] = 0
    r = client.get(CART, headers=shop.h).json()
    st = {i["product_id"]: i for i in r["items"]}
    assert st[shop.bike["id"]]["status"] == "not_listed" and st[shop.bike["id"]]["product"] is None and st[shop.bike["id"]]["unit_price"] is None
    assert st[shop.pads["id"]]["status"] == "out_of_stock"
    assert r["summary"]["subtotal"] == 0 and r["summary"]["has_unavailable_items"] is True
    shop.pads["stock_quantity"] = 1; shop.pads["is_available"] = True
    shop.bike["approval_status"] = "approved"; shop.bike["stock_quantity"] = 1
    assert client.get(CART, headers=shop.h).json()["items"][0]["status"] == "insufficient_stock"      # 2 requested, 1 left


def test_customer_cart_isolation(client, db, auth, shop):
    other = auth(db.add_profile())
    mine = add(client, shop, shop.bike, 1).json()["items"][0]
    assert client.get(CART, headers=other).json()["items"] == []
    assert client.put(f"{CART}/items/{mine['id']}", headers=other, json={"quantity": 3}).status_code == 404
    assert client.delete(f"{CART}/items/{mine['id']}", headers=other).status_code == 404
    client.delete(f"{CART}/clear", headers=other)
    assert client.get(CART, headers=shop.h).json()["items"][0]["quantity"] == 1       # untouched by the other customer
    assert client.post(f"{CART}/items", headers=other, json={"product_id": shop.bike["id"], "user_id": shop.cust}).status_code == 422


def test_cart_size_limit(client, shop, db, monkeypatch):
    monkeypatch.setenv("MAX_CART_ITEMS", "2")
    from app.core.config import get_settings
    get_settings.cache_clear()
    for i in range(2):
        assert add(client, shop, db.add_product(shop.v1["id"], shop.cat, name=f"P{i}")).status_code == 201
    assert add(client, shop, db.add_product(shop.v1["id"], shop.cat, name="P3")).json()["error"]["code"] == "cart_full"


def test_cart_never_creates_orders_or_charges(client, shop):
    add(client, shop, shop.bike, 1)
    assert not shop.db.tables.get("orders") and not shop.db.tables.get("payments")
    assert set(client.get(CART, headers=shop.h).json()["summary"]) == {"distinct_items", "total_quantity", "subtotal", "multi_vendor", "has_unavailable_items", "has_price_changes"}
