import uuid

P = "/api/v1/products"


def names(r):
    return [i["name"] for i in r.json()["items"]]


def setup_market(db):
    _, v1 = db.add_approved_vendor("Alpha Cycles")
    _, v2 = db.add_approved_vendor("Beta Bikes")
    new, used = db.add_category("new_cycle", "New Cycles"), db.add_category("used_cycle", "Used Cycles")
    parts = db.add_category("spare_part", "Spare Parts")
    p = {}
    p["road"] = db.add_product(v1["id"], new, name="Road Racer", brand="Trek", model="X1", price=30000.0, description="Fast carbon frame", created_at="2026-01-03")
    p["used"] = db.add_product(v1["id"], used, name="Old Commuter", brand="Hero", model="C2", price=4000.0, created_at="2026-01-02")
    p["pads"] = db.add_product(v2["id"], parts, name="Brake Pads", brand="Shimano", model="BP-1", price=500.0, stock_quantity=0, created_at="2026-01-04")
    p["feat"] = db.add_product(v2["id"], new, name="Featured Hybrid", brand="Trek", model="H9", price=20000.0, is_featured=True, created_at="2026-01-01")
    return v1, v2, new, used, parts, p


def test_anonymous_sees_only_approved_active_listings_of_approved_vendors(client, db):
    v1, v2, new, used, parts, p = setup_market(db)
    db.add_product(v1["id"], new, name="Pending One", approval_status="pending")
    db.add_product(v1["id"], new, name="Rejected One", approval_status="rejected")
    db.add_product(v1["id"], new, name="Inactive One", is_active=False)
    _, suspended = db.add_approved_vendor("Gone"); suspended["verification_status"] = "suspended"
    db.add_product(suspended["id"], new, name="Suspended Vendor Item")
    r = client.get(P)
    assert r.status_code == 200
    assert sorted(names(r)) == sorted(["Road Racer", "Old Commuter", "Brake Pads", "Featured Hybrid"])
    assert r.json()["total"] == 4


def test_summary_fields_and_no_private_vendor_data(client, db):
    setup_market(db)
    item = client.get(P + "?q=Road").json()["items"][0]
    assert item["price"] == 30000.0 and item["in_stock"] is True and item["vendor"]["business_name"] == "Alpha Cycles"
    assert set(item["vendor"]) == {"id", "business_name", "city", "state", "business_types", "pickup_available"}
    flat = str(item)
    assert "contact_phone" not in flat and "address_line1" not in flat and "review_notes" not in flat and "approval_status" not in flat


def test_search_matches_name_brand_model_description_category(client, db):
    setup_market(db)
    assert names(client.get(P + "?q=racer")) == ["Road Racer"]                       # name, case-insensitive
    assert sorted(names(client.get(P + "?q=trek"))) == ["Featured Hybrid", "Road Racer"]   # brand
    assert names(client.get(P + "?q=BP-1")) == ["Brake Pads"]                         # model
    assert names(client.get(P + "?q=carbon")) == ["Road Racer"]                       # description
    assert sorted(names(client.get(P + "?q=used cycles"))) == ["Old Commuter"]        # category name
    r = client.get(P + "?q=zzzz-nothing")
    assert r.status_code == 200 and r.json() == {"items": [], "total": 0, "page": 1, "limit": 20, "pages": 0}


def test_filters_combine(client, db):
    v1, v2, new, used, parts, p = setup_market(db)
    assert names(client.get(f"{P}?category_id={used['id']}")) == ["Old Commuter"]
    assert sorted(names(client.get(P + "?min_price=4000&max_price=20000"))) == ["Featured Hybrid", "Old Commuter"]
    assert sorted(names(client.get(P + "?brand=trek"))) == ["Featured Hybrid", "Road Racer"]
    assert names(client.get(P + "?condition=used")) == ["Old Commuter"]
    assert names(client.get(P + "?product_type=spare_part")) == ["Brake Pads"]
    assert "Brake Pads" not in names(client.get(P + "?in_stock=true"))
    assert names(client.get(P + "?in_stock=false")) == ["Brake Pads"]
    assert names(client.get(P + "?brand=trek&condition=new&min_price=25000&q=road")) == ["Road Racer"]


def test_category_filter_includes_subcategories(client, db):
    _, v = db.add_approved_vendor()
    parent = db.add_category("spare_part", "Spare Parts")
    kid = db.add_category("spare_part", "Brakes", parent_id=parent["id"])
    db.add_product(v["id"], kid, name="Disc Brake")
    db.add_product(v["id"], parent, name="Generic Part")
    assert sorted(names(client.get(f"{P}?category_id={parent['id']}"))) == ["Disc Brake", "Generic Part"]
    assert names(client.get(f"{P}?category_id={kid['id']}")) == ["Disc Brake"]


def test_sorting(client, db):
    setup_market(db)
    assert names(client.get(P + "?sort_by=price_low_to_high")) == ["Brake Pads", "Old Commuter", "Featured Hybrid", "Road Racer"]
    assert names(client.get(P + "?sort_by=price_high_to_low"))[0] == "Road Racer"
    assert names(client.get(P + "?sort_by=newest")) == ["Brake Pads", "Road Racer", "Old Commuter", "Featured Hybrid"]
    assert names(client.get(P))[0] == "Featured Hybrid"                      # relevance: featured first
    assert client.get(P + "?sort_by=cheapest").status_code == 422


def test_pagination(client, db):
    _, v = db.add_approved_vendor(); c = db.add_category("accessory", "Acc")
    for i in range(7):
        db.add_product(v["id"], c, name=f"Item {i}", created_at=f"2026-02-0{i + 1}")
    p1 = client.get(P + "?limit=3&page=1&sort_by=newest").json()
    p3 = client.get(P + "?limit=3&page=3&sort_by=newest").json()
    assert (p1["total"], p1["pages"], len(p1["items"]), len(p3["items"])) == (7, 3, 3, 1)
    seen = [i["id"] for pg in (1, 2, 3) for i in client.get(f"{P}?limit=3&page={pg}&sort_by=newest").json()["items"]]
    assert len(set(seen)) == 7
    assert client.get(P + "?page=99").json()["items"] == []
    for bad in ("limit=0", "limit=101", "page=0", "page=abc"):
        assert client.get(f"{P}?{bad}").status_code == 422


def test_filter_validation(client, db):
    setup_market(db)
    assert client.get(P + "?min_price=10&max_price=5").status_code == 400
    assert client.get(P + "?min_price=-1").status_code == 422
    assert client.get(P + "?condition=broken").status_code == 422
    assert client.get(P + "?category_id=not-a-uuid").status_code == 422
    assert client.get(P + "?q=" + "x" * 101).status_code == 422


def test_featured_follows_visibility(client, db):
    v1, v2, new, *_ = setup_market(db)
    db.add_product(v1["id"], new, name="Featured But Pending", is_featured=True, approval_status="pending")
    db.add_product(v1["id"], new, name="Featured But Inactive", is_featured=True, is_active=False)
    r = client.get(P + "/featured")
    assert r.status_code == 200 and [i["name"] for i in r.json()] == ["Featured Hybrid"]


def test_detail(client, db):
    v1, v2, new, used, parts, p = setup_market(db)
    db.add_image(p["road"]["id"], "a/1.jpg", is_primary=True, sort_order=0)
    db.add_image(p["road"]["id"], "a/2.jpg", sort_order=1)
    d = client.get(f"{P}/{p['road']['id']}").json()
    assert d["name"] == "Road Racer" and d["description"] == "Fast carbon frame" and d["category"]["name"] == "New Cycles"
    assert [i["storage_path"] for i in d["images"]] == ["a/1.jpg", "a/2.jpg"] and d["primary_image_url"].endswith("/product-images/a/1.jpg")
    assert d["vendor"]["business_name"] == "Alpha Cycles" and d["in_stock"] is True and d["stock_quantity"] == 5
    assert client.get(f"{P}/{p['pads']['id']}").json()["in_stock"] is False       # listed, out of stock
    assert client.get(f"{P}/{uuid.uuid4()}").status_code == 404
    assert client.get(f"{P}/nope").status_code == 422


def test_hidden_listings_are_404_in_detail(client, db):
    v1, _, new, *_ = setup_market(db)
    for kw in ({"approval_status": "pending"}, {"approval_status": "rejected"}, {"is_active": False}):
        assert client.get(f"{P}/{db.add_product(v1['id'], new, **kw)['id']}").status_code == 404


def test_public_endpoints_use_the_anonymous_client_not_a_user(client, db):
    setup_market(db)
    client.get(P)
    assert db.tokens_used == []          # no user token was ever created for public reads
