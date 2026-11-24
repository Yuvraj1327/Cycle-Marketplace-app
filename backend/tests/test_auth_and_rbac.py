import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from app.core import dependencies as d
from app.main import app as main_app


# ---------------- /auth/me and the authentication dependency chain ----------------
def test_health_still_public(client):
    assert client.get("/health").json()["status"] == "ok"


def test_no_credentials_401(client):
    r = client.get("/api/v1/auth/me")
    assert r.status_code == 401 and r.headers["www-authenticate"] == "Bearer"
    assert r.json()["error"]["code"] == "not_authenticated"


def test_wrong_scheme_and_garbage_401(client):
    assert client.get("/api/v1/auth/me", headers={"Authorization": "Basic abc"}).status_code == 401
    r = client.get("/api/v1/auth/me", headers={"Authorization": "Bearer garbage"})
    assert r.status_code == 401 and r.json()["error"]["code"] == "invalid_token"


def test_expired_token_401(client, db, auth):
    uid = db.add_profile()
    r = client.get("/api/v1/auth/me", headers=auth(uid, exp_in=-100))
    assert r.status_code == 401 and r.json()["error"]["code"] == "token_expired"


def test_me_returns_identity_and_role_from_database(client, db, auth):
    uid = db.add_profile(role="customer")
    # the token tries to claim admin through user-controlled metadata: must be ignored
    r = client.get("/api/v1/auth/me", headers=auth(uid, extra={"user_metadata": {"role": "admin"}, "app_role": "admin"}))
    assert r.status_code == 200
    body = r.json()
    assert body["id"] == uid and body["role"] == "customer" and body["status"] == "active"
    assert body["profile"]["id"] == uid and body["session"]["session_id"] == "sess-1"
    assert body["vendor_verification_status"] is None


def test_me_for_vendor_includes_verification_status(client, db, auth):
    uid = db.add_profile(role="vendor"); db.add_vendor(uid, "pending")
    assert client.get("/api/v1/auth/me", headers=auth(uid)).json()["vendor_verification_status"] == "pending"


def test_valid_token_without_profile_is_403(client, db, auth):
    r = client.get("/api/v1/auth/me", headers=auth("22222222-2222-2222-2222-222222222222"))
    assert r.status_code == 403


def test_user_token_is_what_reaches_the_database(client, db, make_token):
    uid = db.add_profile()
    token = make_token(uid)
    client.get("/api/v1/profiles/me", headers={"Authorization": f"Bearer {token}"})
    assert db.tokens_used and set(db.tokens_used) == {token}   # never the service-role key


def test_restricted_account_can_read_me_but_not_write(client, db, auth):
    uid = db.add_profile(status="restricted")
    assert client.get("/api/v1/auth/me", headers=auth(uid)).json()["status"] == "restricted"
    r = client.put("/api/v1/profiles/me", headers=auth(uid), json={"full_name": "x"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "account_restricted"


def test_logout_forwards_token_to_supabase_auth(client, db, auth, make_token, monkeypatch):
    from app.services import auth_service
    calls = []
    monkeypatch.setattr(auth_service, "revoke_session", lambda t, s: calls.append((t, s)))
    uid = db.add_profile(); token = make_token(uid)
    r = client.post("/api/v1/auth/logout?scope=global", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 204 and calls == [(token, "global")]
    assert client.post("/api/v1/auth/logout?scope=bogus", headers={"Authorization": f"Bearer {token}"}).status_code == 422
    assert client.post("/api/v1/auth/logout").status_code == 401


def test_unknown_route_uses_error_shape(client):
    r = client.get("/api/v1/nope")
    assert r.status_code == 404 and r.json()["error"]["code"] == "not_found"


# ---------------- role-based access control on a throwaway app using the real dependencies ----------------
@pytest.fixture
def rbac_client(db):
    t = FastAPI()
    t.exception_handlers.update(main_app.exception_handlers)

    @t.get("/customer")
    def c(u=Depends(d.require_customer)): return {"role": u.role}

    @t.get("/vendor")
    def v(u=Depends(d.require_vendor)): return {"role": u.role}

    @t.get("/admin")
    def a(u=Depends(d.require_admin)): return {"role": u.role}

    @t.get("/approved-vendor")
    def av(x=Depends(d.require_approved_vendor)): return {"vendor": x.vendor["business_name"]}

    return TestClient(t, raise_server_exceptions=False)


@pytest.mark.parametrize("role,path,expected", [
    ("customer", "/customer", 200), ("customer", "/vendor", 403), ("customer", "/admin", 403),
    ("vendor", "/vendor", 200), ("vendor", "/customer", 403), ("vendor", "/admin", 403),
    ("admin", "/admin", 200), ("admin", "/customer", 403), ("admin", "/vendor", 403),
])
def test_role_matrix(rbac_client, db, auth, role, path, expected):
    uid = db.add_profile(role=role)
    assert rbac_client.get(path, headers=auth(uid)).status_code == expected


def test_protected_routes_need_a_token(rbac_client):
    for p in ("/customer", "/vendor", "/admin", "/approved-vendor"):
        assert rbac_client.get(p).status_code == 401


def test_inactive_admin_is_not_admin(rbac_client, db, auth):
    uid = db.add_profile(role="admin", status="inactive")
    r = rbac_client.get("/admin", headers=auth(uid))
    assert r.status_code == 403 and r.json()["error"]["code"] == "account_inactive"


@pytest.mark.parametrize("status,code", [("pending", "vendor_pending"), ("rejected", "vendor_rejected"), ("suspended", "vendor_suspended")])
def test_unapproved_vendors_blocked(rbac_client, db, auth, status, code):
    uid = db.add_profile(role="vendor"); db.add_vendor(uid, status)
    r = rbac_client.get("/approved-vendor", headers=auth(uid))
    assert r.status_code == 403 and r.json()["error"]["code"] == code


def test_unregistered_vendor_blocked_and_approved_allowed(rbac_client, db, auth):
    uid = db.add_profile(role="vendor")
    assert rbac_client.get("/approved-vendor", headers=auth(uid)).json()["error"]["code"] == "vendor_not_registered"
    db.add_vendor(uid, "approved")
    assert rbac_client.get("/approved-vendor", headers=auth(uid)).json() == {"vendor": "Shop"}


def test_customer_cannot_reach_approved_vendor_ops(rbac_client, db, auth):
    uid = db.add_profile(role="customer")
    assert rbac_client.get("/approved-vendor", headers=auth(uid)).status_code == 403
