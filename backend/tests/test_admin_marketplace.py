import uuid

import pytest

AP = "/api/v1/admin/products"
AB = "/api/v1/admin/banners"
PUB = "/api/v1/products"
BAN = "/api/v1/banners"


@pytest.fixture
def m(db, auth):
    admin = db.add_profile(role="admin")
    vuid, vendor = db.add_approved_vendor("Alpha")
    cat = db.add_category("new_cycle")
    pending = db.add_product(vendor["id"], cat, name="Pending Bike", approval_status="pending")
    live = db.add_product(vendor["id"], cat, name="Live Bike")
    return type("M", (), {"db": db, "h": auth(admin), "auth": auth, "vendor": vendor, "vuid": vuid, "cat": cat, "pending": pending, "live": live})


def test_every_admin_route_is_admin_only(client, db, auth, m):
    pid = m.live["id"]
    routes = [("get", AP), ("get", f"{AP}/{pid}"), ("patch", f"{AP}/{pid}/approval"), ("patch", f"{AP}/{pid}/status"),
              ("patch", f"{AP}/{pid}/featured"), ("get", AB), ("post", AB), ("put", f"{AB}/{uuid.uuid4()}"), ("delete", f"{AB}/{uuid.uuid4()}")]
    for who in (None, db.add_profile(), m.vuid):
        h = auth(who) if who else {}
        for method, url in routes:
            r = getattr(client, method)(url, headers=h, **({"json": {}} if method in ("post", "put", "patch") else {}))
            assert r.status_code == (401 if not who else 403), (who, method, url, r.status_code)


def test_review_queue_filters_and_vendor_details(client, db, m):
    db.add_product(m.vendor["id"], m.cat, name="Rejected", approval_status="rejected")
    db.add_product(m.vendor["id"], m.cat, name="Off", is_active=False)
    used = db.add_category("used_cycle"); _, other = db.add_approved_vendor("Beta")
    db.add_product(other["id"], used, name="Used Beta")
    names = lambda q: sorted(i["name"] for i in client.get(f"{AP}{q}", headers=m.h).json()["items"])  # noqa: E731
    assert names("?moderation_status=pending") == ["Pending Bike"]
    assert names("?moderation_status=rejected") == ["Rejected"]
    assert names("?moderation_status=inactive") == ["Off"]
    assert names("?moderation_status=approved") == ["Live Bike", "Used Beta"]
    assert names(f"?vendor_id={other['id']}") == ["Used Beta"]
    assert names("?condition=used") == ["Used Beta"]
    assert names(f"?category_id={used['id']}") == ["Used Beta"]
    assert len(names("")) == 5 and names("?q=used") == ["Used Beta"]
    assert client.get(f"{AP}?moderation_status=bogus", headers=m.h).status_code == 422
    item = client.get(f"{AP}?moderation_status=pending", headers=m.h).json()["items"][0]
    assert item["vendor_admin"]["business_name"] == "Alpha" and item["vendor_admin"]["verification_status"] == "approved"
    assert "contact_phone" in item["vendor_admin"] and item["moderation_status"] == "pending"
    assert client.get(f"{AP}/{item['id']}", headers=m.h).json()["id"] == item["id"]
    assert client.get(f"{AP}/{uuid.uuid4()}", headers=m.h).status_code == 404


def test_approve_makes_listing_public_and_records_reviewer(client, db, m):
    assert client.get(f"{PUB}/{m.pending['id']}").status_code == 404
    r = client.patch(f"{AP}/{m.pending['id']}/approval", headers=m.h, json={"approval_status": "approved", "review_notes": "Looks good"})
    assert r.status_code == 200 and r.json()["moderation_status"] == "approved" and r.json()["review_notes"] == "Looks good"
    assert client.get(f"{PUB}/{m.pending['id']}").status_code == 200


def test_reject_needs_reason_and_hides_listing(client, db, m):
    url = f"{AP}/{m.live['id']}/approval"
    r = client.patch(url, headers=m.h, json={"approval_status": "rejected"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "review_notes_required"
    assert client.patch(url, headers=m.h, json={"approval_status": "rejected", "review_notes": "  "}).status_code == 422
    ok = client.patch(url, headers=m.h, json={"approval_status": "rejected", "review_notes": "Misleading photos"})
    assert ok.json()["approval_status"] == "rejected"
    assert client.get(f"{PUB}/{m.live['id']}").status_code == 404
    assert client.patch(url, headers=m.h, json={"approval_status": "maybe"}).status_code == 422
    assert client.patch(f"{AP}/{uuid.uuid4()}/approval", headers=m.h, json={"approval_status": "approved"}).status_code == 404


def test_vendor_sees_rejection_note_and_cannot_self_approve(client, db, m):
    client.patch(f"{AP}/{m.live['id']}/approval", headers=m.h, json={"approval_status": "rejected", "review_notes": "Fix title"})
    h = m.auth(m.vuid)
    mine = client.get(f"/api/v1/vendor/products/{m.live['id']}", headers=h).json()
    assert mine["approval_status"] == "rejected" and mine["review_notes"] == "Fix title"
    assert client.patch(f"/api/v1/vendor/products/{m.live['id']}", headers=h, json={"approval_status": "approved"}).status_code == 422


def test_deactivate_and_reactivate(client, db, m):
    featured = client.patch(f"{AP}/{m.live['id']}/featured", headers=m.h, json={"is_featured": True})
    assert featured.status_code == 200 and featured.json()["is_featured"] is True
    off = client.patch(f"{AP}/{m.live['id']}/status", headers=m.h, json={"is_active": False}).json()
    assert off["moderation_status"] == "inactive" and off["is_featured"] is False
    assert client.get(f"{PUB}/{m.live['id']}").status_code == 404 and client.get(PUB + "/featured").json() == []
    assert client.patch(f"{AP}/{m.live['id']}/status", headers=m.h, json={"is_active": True}).json()["moderation_status"] == "approved"
    assert client.get(f"{PUB}/{m.live['id']}").status_code == 200


def test_featured_selection_rules(client, db, m):
    assert client.patch(f"{AP}/{m.pending['id']}/featured", headers=m.h, json={"is_featured": True}).json()["error"]["code"] == "not_publicly_visible"
    assert client.patch(f"{AP}/{m.live['id']}/featured", headers=m.h, json={"is_featured": True}).status_code == 200
    assert [p["name"] for p in client.get(PUB + "/featured").json()] == ["Live Bike"]
    assert [i["name"] for i in client.get(f"{AP}?is_featured=true", headers=m.h).json()["items"]] == ["Live Bike"]
    assert client.patch(f"{AP}/{m.live['id']}/featured", headers=m.h, json={"is_featured": False}).json()["is_featured"] is False
    assert client.get(PUB + "/featured").json() == []
    assert client.patch(f"{AP}/{m.live['id']}/featured", headers=m.h, json={"is_featured": "yes please", "x": 1}).status_code == 422


def test_inactive_admin_account_is_locked_out(client, db, auth):
    uid = db.add_profile(role="admin", status="inactive")
    assert client.get(AP, headers=auth(uid)).status_code == 403


# ---------------- banners ----------------
BODY = {"title": "Monsoon Sale", "subtitle": "Up to 20% off", "image_path": "banners/monsoon.jpg", "sort_order": 2}


def test_banner_crud_and_public_visibility(client, db, m):
    r = client.post(AB, headers=m.h, json=BODY)
    assert r.status_code == 201
    b = r.json()
    assert b["is_active"] is True and b["action_type"] == "none" and b["image_url"].endswith("/storage/v1/object/public/banners/banners/monsoon.jpg")
    first = client.get(BAN)
    assert first.status_code == 200 and [x["title"] for x in first.json()] == ["Monsoon Sale"] and "is_active" not in first.json()[0]
    client.post(AB, headers=m.h, json={**BODY, "title": "Early", "sort_order": 1})
    assert [x["title"] for x in client.get(BAN).json()] == ["Early", "Monsoon Sale"]
    off = client.put(f"{AB}/{b['id']}", headers=m.h, json={"is_active": False, "subtitle": None})
    assert off.status_code == 200 and off.json()["is_active"] is False and off.json()["subtitle"] is None
    assert [x["title"] for x in client.get(BAN).json()] == ["Early"]                       # inactive hidden publicly
    assert len(client.get(AB, headers=m.h).json()) == 2                                    # admin still sees it
    assert client.delete(f"{AB}/{b['id']}", headers=m.h).status_code == 204
    assert client.delete(f"{AB}/{b['id']}", headers=m.h).status_code == 404
    assert client.put(f"{AB}/{b['id']}", headers=m.h, json={"title": "x"}).status_code == 404


def test_banner_display_window(client, db, m):
    client.post(AB, headers=m.h, json={**BODY, "title": "Future", "starts_at": "2999-01-01T00:00:00+00:00"})
    client.post(AB, headers=m.h, json={**BODY, "title": "Expired", "ends_at": "2000-01-01T00:00:00+00:00"})
    # fake clock uses ISO strings; both are outside the window for "now" = 2026-01-01
    assert [x["title"] for x in client.get(BAN).json()] == []
    assert client.post(AB, headers=m.h, json={**BODY, "starts_at": "2026-02-01T00:00:00+00:00", "ends_at": "2026-01-01T00:00:00+00:00"}).status_code == 422


def test_banner_destination_validation(client, db, m):
    pid = str(uuid.uuid4())
    assert client.post(AB, headers=m.h, json={**BODY, "action_type": "product", "action_value": pid}).status_code == 201
    assert client.post(AB, headers=m.h, json={**BODY, "action_type": "url", "action_value": "https://example.com/sale"}).status_code == 201
    for bad in ({"action_type": "product", "action_value": "not-a-uuid"}, {"action_type": "product"}, {"action_type": "url", "action_value": "javascript:alert(1)"},
                {"action_type": "url", "action_value": "http://insecure.example"}, {"action_type": "none", "action_value": "x"},
                {"action_type": "teleport"}, {"image_path": "../../etc/passwd.jpg"}, {"image_path": "x.gif"}, {"title": ""}):
        assert client.post(AB, headers=m.h, json={**BODY, **bad}).status_code == 422, bad
    b = client.post(AB, headers=m.h, json=BODY).json()
    assert client.put(f"{AB}/{b['id']}", headers=m.h, json={"action_type": "url", "action_value": "javascript:x"}).status_code == 422
    assert client.put(f"{AB}/{b['id']}", headers=m.h, json={"action_type": "category", "action_value": pid}).json()["action_value"] == pid
    assert client.put(f"{AB}/{b['id']}", headers=m.h, json={}).status_code == 400


def test_banner_is_stamped_with_creating_admin(client, db, m):
    b = client.post(AB, headers=m.h, json=BODY).json()
    assert next(r for r in db.tables["banners"] if r["id"] == b["id"])["created_by"] == db.tables["profiles"][0]["id"]
