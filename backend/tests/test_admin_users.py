"""Step 9: admin customer/vendor management and dashboard summary."""
import uuid

C = "/api/v1/admin/customers"
V = "/api/v1/admin/vendors"
D = "/api/v1/admin/dashboard"


def pending_vendor(world, name="Pending Cycles", **extra):
    uid = world.db.add_profile(role="vendor", full_name=f"{name} Owner", email=f"{name.split()[0].lower()}@shop.test", phone="+919811100000")
    row = world.db.add_vendor(uid, "pending", business_name=name, city="Nashik", business_types=["service_provider"], **extra)
    return uid, row


# ------------------------------------------------------------------------------------------------ RBAC
def test_every_admin_endpoint_rejects_anonymous_customers_and_vendors(client, world):
    vid = world.va["id"]
    calls = [("get", D), ("get", C), ("get", f"{C}/{world.cust}"), ("patch", f"{C}/{world.cust}/status"), ("get", V), ("get", f"{V}/{vid}"),
             ("post", f"{V}/{vid}/approve"), ("post", f"{V}/{vid}/reject"), ("post", f"{V}/{vid}/suspend"), ("post", f"{V}/{vid}/reinstate"),
             ("patch", f"{V}/{vid}/account-status")]
    for method, url in calls:
        body = {"json": {"status": "inactive", "reason": "abc", }} if method == "patch" else ({"json": {"reason": "abc"}} if method == "post" else {})
        assert getattr(client, method)(url, **body).status_code == 401, (method, url)
        for who in (world.h, world.hva, world.hvb):
            assert getattr(client, method)(url, headers=who, **body).status_code == 403, (method, url)


def test_admin_cannot_be_created_or_promoted_through_these_endpoints(client, world):
    r = client.patch(f"{C}/{world.cust}/status", json={"status": "active", "role": "admin"}, headers=world.ha)
    assert r.status_code == 422
    assert world.db.profile(world.cust)["role"] == "customer"
    # an admin's own account is not a "customer": the customer endpoints do not see it
    assert client.get(f"{C}/{world.admin}", headers=world.ha).status_code == 404
    assert client.patch(f"{C}/{world.admin}/status", json={"status": "inactive", "reason": "nope!"}, headers=world.ha).status_code == 404
    assert world.db.profile(world.admin)["status"] == "active"


def test_inactive_admin_is_refused(client, world):
    world.db.profile(world.admin)["status"] = "inactive"
    assert client.get(D, headers=world.ha).status_code == 403


# ------------------------------------------------------------------------------------------------ customers
def test_customer_list_search_filter_sort_and_counts(client, world):
    world.add(world.bike)
    assert world.checkout().status_code == 201
    extra = world.db.add_profile(full_name="Zed Zimmer", email="zed@example.org", phone="+919877700000", status="restricted")
    r = client.get(C, headers=world.ha).json()
    assert r["total"] == 3 and {i["id"] for i in r["items"]} == {world.cust, world.other, extra}
    assert all("role" not in i and "password" not in str(i) for i in r["items"])
    mine = next(i for i in r["items"] if i["id"] == world.cust)
    assert mine["order_count"] == 1 and mine["booking_count"] == 0
    assert [i["id"] for i in client.get(C + "?q=zimmer", headers=world.ha).json()["items"]] == [extra]
    assert [i["id"] for i in client.get(C + "?q=zed@example", headers=world.ha).json()["items"]] == [extra]
    assert [i["id"] for i in client.get(C + "?q=9877700", headers=world.ha).json()["items"]] == [extra]
    assert [i["id"] for i in client.get(C + "?status=restricted", headers=world.ha).json()["items"]] == [extra]
    assert client.get(C + "?status=bogus", headers=world.ha).status_code == 422
    assert client.get(C + "?q=%25%2C)(", headers=world.ha).status_code == 200          # filter-language characters are neutralised
    assert client.get(C + "?sort=name", headers=world.ha).json()["items"][-1]["id"] == extra
    p2 = client.get(C + "?limit=1&page=2", headers=world.ha).json()
    assert p2["total"] == 3 and p2["pages"] == 3 and len(p2["items"]) == 1
    assert world.ua not in {i["id"] for i in r["items"]}, "vendors and admins are not customers"


def test_customer_detail_includes_addresses_and_activity(client, world):
    d = client.get(f"{C}/{world.cust}", headers=world.ha).json()
    assert d["id"] == world.cust and d["addresses"][0]["address_line1"] == "1 MG Rd" and d["activity"] == []
    assert client.get(f"{C}/{uuid.uuid4()}", headers=world.ha).status_code == 404
    assert client.get(f"{C}/{world.ua}", headers=world.ha).status_code == 404            # a vendor is not a customer
    assert client.get(f"{C}/nope", headers=world.ha).status_code == 422


def test_customer_status_changes_need_a_reason_are_audited_and_block_the_account(client, world):
    u = f"{C}/{world.cust}/status"
    assert client.patch(u, json={"status": "inactive"}, headers=world.ha).status_code == 422
    assert client.patch(u, json={"status": "inactive", "reason": "ab"}, headers=world.ha).status_code == 422
    assert client.patch(u, json={"status": "bogus", "reason": "abcd"}, headers=world.ha).status_code == 422
    assert world.db.profile(world.cust)["status"] == "active", "nothing changed by the refused attempts"
    r = client.patch(u, json={"status": "inactive", "reason": "Fraud report #12"}, headers=world.ha)
    assert r.status_code == 200 and r.json()["status"] == "inactive"
    assert r.json()["activity"][0]["action"] == "customer_inactive" and r.json()["activity"][0]["details"]["reason"] == "Fraud report #12"
    assert r.json()["activity"][0]["actor_id"] == world.admin
    assert client.patch(u, json={"status": "inactive", "reason": "again!"}, headers=world.ha).status_code == 409          # repeated request
    assert client.get("/api/v1/addresses", headers=world.h).status_code == 403                                              # the customer is locked out by the backend
    r = client.patch(u, json={"status": "restricted", "reason": "Chargebacks"}, headers=world.ha)
    assert r.json()["status"] == "restricted"
    r = client.patch(u, json={"status": "active"}, headers=world.ha)                                                       # activating needs no reason
    assert r.status_code == 200 and r.json()["status"] == "active" and len(r.json()["activity"]) == 3
    assert client.get("/api/v1/addresses", headers=world.h).status_code == 200


def test_deactivating_a_customer_keeps_orders(client, world):
    world.add(world.bike)
    world.checkout()
    client.patch(f"{C}/{world.cust}/status", json={"status": "inactive", "reason": "Review pending"}, headers=world.ha)
    assert len(world.db.tables["orders"]) == 1
    assert client.get("/api/v1/admin/orders?customer_id=" + world.cust, headers=world.ha).json()["total"] == 1


# ------------------------------------------------------------------------------------------------ vendors
def test_vendor_list_filters_search_counts(client, world):
    pu, prow = pending_vendor(world)
    r = client.get(V, headers=world.ha).json()
    assert r["total"] == 3
    a = next(i for i in r["items"] if i["id"] == world.va["id"])
    assert a["business_name"] == "Alpha" and a["verification_status"] == "approved" and a["account_status"] == "active" and a["product_count"] == 1
    assert [i["id"] for i in client.get(V + "?verification_status=pending", headers=world.ha).json()["items"]] == [prow["id"]]
    assert [i["id"] for i in client.get(V + "?business_type=service_provider", headers=world.ha).json()["items"]] == [prow["id"]]
    assert [i["id"] for i in client.get(V + "?q=nashik", headers=world.ha).json()["items"]] == [prow["id"]]
    assert [i["id"] for i in client.get(V + "?q=cycles owner", headers=world.ha).json()["items"]] == [prow["id"]], "owner name is searchable"
    assert [i["id"] for i in client.get(V + "?q=pending@shop", headers=world.ha).json()["items"]] == [prow["id"]], "owner e-mail is searchable"
    world.db.profile(world.ub)["status"] = "inactive"
    assert [i["id"] for i in client.get(V + "?account_status=inactive", headers=world.ha).json()["items"]] == [world.vb["id"]]
    assert world.vb["id"] not in {i["id"] for i in client.get(V + "?account_status=active", headers=world.ha).json()["items"]}
    assert client.get(V + "?verification_status=bogus", headers=world.ha).status_code == 422
    assert client.get(V + "?business_type=bogus", headers=world.ha).status_code == 422
    assert [i["business_name"] for i in client.get(V + "?sort=name", headers=world.ha).json()["items"]] == ["Alpha", "Beta", "Pending Cycles"]


def test_vendor_detail_has_the_full_application(client, world):
    pu, prow = pending_vendor(world, shop_image_paths=[f"{uuid.uuid4()}/shop/a.jpg"], operating_hours={"mon": {"closed": False, "open": "09:00", "close": "18:00"}},
                              service_area_postal_codes=["411001"], pickup_available=True)
    d = client.get(f"{V}/{prow['id']}", headers=world.ha).json()
    assert d["business_name"] == "Pending Cycles" and d["owner_name"] == "Pending Cycles Owner" and d["owner_phone"] == "+919811100000"
    assert d["operating_hours"]["mon"]["open"] == "09:00" and d["service_area_postal_codes"] == ["411001"] and d["pickup_available"] is True
    assert d["shop_image_urls"] and d["shop_image_urls"][0].endswith(d["shop_image_paths"][0]) and "shop-images" in d["shop_image_urls"][0]
    assert d["reviewed_at"] is None and d["activity"] == []
    assert client.get(f"{V}/{uuid.uuid4()}", headers=world.ha).status_code == 404


def test_approval_workflow_decisions_are_audited_notified_and_idempotent(client, world):
    pu, prow = pending_vendor(world)
    base = f"{V}/{prow['id']}"
    assert client.get("/api/v1/vendor/products", headers=world.h).status_code == 403
    # not approved yet: the vendor cannot operate
    from tests.conftest import auth  # noqa: F401
    r = client.post(base + "/approve", headers=world.ha)
    assert r.status_code == 200 and r.json()["verification_status"] == "approved"
    assert r.json()["reviewed_by"] == world.admin and r.json()["reviewed_at"] and r.json()["rejection_reason"] is None
    assert r.json()["activity"][0]["action"] == "vendor_approved"
    assert any(n["user_id"] == pu and n["title"] == "Application approved" for n in world.db.rows("notifications"))
    again = client.post(base + "/approve", headers=world.ha)
    assert again.status_code == 409 and again.json()["error"]["code"] == "already_approved"
    assert len([a for a in world.db.rows("audit_log") if a["entity_id"] == prow["id"]]) == 1, "the repeated request wrote nothing"
    assert client.post(base + "/reject", json={"reason": "too late"}, headers=world.ha).status_code == 409          # approved vendors are suspended, not rejected


def test_reject_needs_a_reason_and_shows_it_to_the_vendor(client, world, auth):
    pu, prow = pending_vendor(world)
    base = f"{V}/{prow['id']}"
    assert client.post(base + "/reject", json={}, headers=world.ha).status_code == 422
    assert client.post(base + "/reject", json={"reason": "no"}, headers=world.ha).status_code == 422
    r = client.post(base + "/reject", json={"reason": "Shop photos were unclear"}, headers=world.ha)
    assert r.status_code == 200 and r.json()["verification_status"] == "rejected" and r.json()["rejection_reason"] == "Shop photos were unclear"
    me = client.get("/api/v1/vendors/me/status", headers=auth(pu)).json()
    assert me["verification_status"] == "rejected" and me["rejection_reason"] == "Shop photos were unclear" and me["can_operate"] is False
    assert client.get("/api/v1/vendor/products", headers=auth(pu)).status_code == 403
    assert client.post(base + "/reject", json={"reason": "again please"}, headers=world.ha).status_code == 409
    # a rejected application can be approved after review
    r = client.post(base + "/approve", json={"note": "Photos fixed"}, headers=world.ha)
    assert r.json()["verification_status"] == "approved" and r.json()["rejection_reason"] is None and r.json()["review_notes"] == "Photos fixed"
    assert client.get("/api/v1/vendor/products", headers=auth(pu)).status_code == 200


def test_suspend_blocks_the_vendor_and_reinstate_restores_it(client, world):
    base = f"{V}/{world.va['id']}"
    assert client.get("/api/v1/vendor/products", headers=world.hva).status_code == 200
    assert client.post(base + "/suspend", json={}, headers=world.ha).status_code == 422
    r = client.post(base + "/suspend", json={"reason": "Counterfeit parts"}, headers=world.ha)
    assert r.json()["verification_status"] == "suspended" and r.json()["rejection_reason"] == "Counterfeit parts"
    assert client.get("/api/v1/vendor/products", headers=world.hva).status_code == 403
    assert client.get("/api/v1/vendor/orders", headers=world.hva).status_code == 403
    assert client.post(base + "/suspend", json={"reason": "once more"}, headers=world.ha).status_code == 409
    assert client.post(base + "/approve", headers=world.ha).status_code == 409                       # suspended vendors are reinstated, not re-approved
    r = client.post(base + "/reinstate", headers=world.ha)
    assert r.json()["verification_status"] == "approved"
    assert client.get("/api/v1/vendor/products", headers=world.hva).status_code == 200
    assert client.post(base + "/reinstate", headers=world.ha).status_code == 409
    assert [a["action"] for a in r.json()["activity"]] == ["vendor_approved", "vendor_suspended"]
    assert len(world.db.tables["products"]) == 2, "products and history are never deleted"


def test_vendor_account_status_is_separate_from_verification(client, world):
    base = f"{V}/{world.va['id']}/account-status"
    assert client.patch(base, json={"status": "inactive"}, headers=world.ha).status_code == 422
    r = client.patch(base, json={"status": "inactive", "reason": "Owner request"}, headers=world.ha)
    assert r.status_code == 200 and r.json()["account_status"] == "inactive" and r.json()["verification_status"] == "approved"
    assert client.get("/api/v1/vendor/products", headers=world.hva).status_code == 403            # inactive login account
    assert client.patch(base, json={"status": "inactive", "reason": "again!"}, headers=world.ha).status_code == 409
    assert client.patch(base, json={"status": "active"}, headers=world.ha).json()["account_status"] == "active"
    assert client.get("/api/v1/vendor/products", headers=world.hva).status_code == 200


def test_vendors_cannot_touch_admin_endpoints_or_their_own_verification(client, world):
    assert client.post(f"{V}/{world.va['id']}/suspend", json={"reason": "self"}, headers=world.hva).status_code == 403
    assert client.put("/api/v1/vendors/me", json={"verification_status": "approved"}, headers=world.hva).status_code == 422


# ------------------------------------------------------------------------------------------------ dashboard
def test_dashboard_summary_counts_come_from_the_database(client, world):
    pending_vendor(world)
    world.add(world.bike)
    world.checkout()
    world.db.rows("service_bookings")        # (empty) table exists
    d = client.get(D, headers=world.ha).json()
    assert d["customers"]["total"] == 2 and d["customers"]["by_status"] == {"active": 2}
    assert d["vendors"]["total"] == 3 and d["vendors"]["by_verification"] == {"approved": 2, "pending": 1}
    assert d["orders"]["total"] == 1 and d["orders"]["by_status"] == {"confirmed": 1}
    assert d["orders"]["value_completed"] == 0 and d["orders"]["value_confirmed"] > 0
    assert d["bookings"] == {"total": 0, "by_status": {}}
    assert len(d["series"]["orders"]) == 30 and d["series"]["orders"][0]["day"] == d["period"]["from"] and d["series"]["orders"][-1]["day"] == d["period"]["to"]
    one = client.get(D + "?from=2026-01-01&to=2026-01-03", headers=world.ha).json()
    assert [x["day"] for x in one["series"]["customers"]] == ["2026-01-01", "2026-01-02", "2026-01-03"]
    assert sum(x["count"] for x in one["series"]["customers"]) == one["customers"]["new_in_period"] == 2


def test_dashboard_validates_the_period(client, world):
    assert client.get(D + "?from=2026-02-01&to=2026-01-01", headers=world.ha).status_code == 422
    assert client.get(D + "?from=2024-01-01&to=2026-01-01", headers=world.ha).status_code == 422
    assert client.get(D + "?from=bogus", headers=world.ha).status_code == 422
