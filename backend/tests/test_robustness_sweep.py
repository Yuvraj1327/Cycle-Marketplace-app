"""Step 12 robustness sweep: every endpoint in the OpenAPI document is called as every kind of caller with hostile input (random ids, empty / wrong-typed /
non-JSON bodies, absurd paging). Nothing may answer 5xx, and every 4xx must use the platform's error shape. This finds unhandled exceptions that the
targeted tests never trigger."""
import itertools
import re
import uuid

import httpx
import pytest

from app.main import app

SKIP = {("POST", "/api/v1/payments/webhook")}                       # public + signature-protected: covered by test_payments.py with real signatures
NETWORK_503_OK = ("/auth/logout", "/images")                          # these legitimately call Supabase; with the network blocked they answer 503, not 500


@pytest.fixture
def callers(db, auth, client, monkeypatch):
    from app.integrations import supabase as sb
    monkeypatch.setattr(sb, "revoke_session", lambda *a, **k: None)
    import app.services.auth_service as auth_service
    monkeypatch.setattr(auth_service, "revoke_session", lambda *a, **k: None, raising=False)

    def blocked(*a, **k):
        raise httpx.ConnectError("network blocked in tests")
    for fn in ("head", "get", "post", "request", "put", "delete"):
        monkeypatch.setattr(httpx, fn, blocked)
    cust, other = db.add_profile(), db.add_profile()
    admin = db.add_profile(role="admin")
    vu, vendor = db.add_approved_vendor("Sweep Shop")
    pending_user = db.add_profile(role="vendor")
    db.add_vendor(pending_user, "pending")
    cat = db.add_category("new_cycle", "Cycles")
    db.add_product(vendor["id"], cat, name="Sweep Bike", price=1000.0, stock_quantity=5)
    return {"anon": {}, "customer": auth(cust), "other": auth(other), "vendor": auth(vu), "pending_vendor": auth(pending_user), "admin": auth(admin)}


def operations():
    for path, item in app.openapi()["paths"].items():
        for method, op in item.items():
            if method in ("get", "post", "put", "patch", "delete") and (method.upper(), path) not in SKIP:
                yield method.upper(), path, op


def fill(path: str, value: str) -> str:
    return re.sub(r"\{[^}]+\}", value, path)


def check(r, label):
    assert r.status_code < 500 or (r.status_code == 503 and any(m in label for m in NETWORK_503_OK)), (label, r.status_code, r.text[:200])
    if 400 <= r.status_code < 500:
        body = r.json()
        assert "error" in body and {"code", "message"} <= set(body["error"]), (label, r.status_code, r.text[:200])


def test_no_endpoint_ever_answers_5xx_to_hostile_input(client, callers):
    seen = 0
    for (method, path, op), who in itertools.product(list(operations()), callers):
        headers = callers[who]
        for ident in (str(uuid.uuid4()), "not-a-uuid"):
            url = fill(path, ident)
            label = f"{who} {method} {url}"
            bodies = [None] if method in ("GET", "DELETE") else [{}, {"unexpected": 1, "role": "admin"}, [], {"status": 12345, "amount": "NaN", "reason": "x" * 5000}]
            for body in bodies:
                kw = {"json": body} if body is not None else {}
                if method == "POST" and "refunds" in url:
                    headers = {**callers[who], "Idempotency-Key": "sweep-key-0001"}
                check(client.request(method, url, headers=headers, **kw), label)
                seen += 1
            if method in ("POST", "PUT", "PATCH"):
                check(client.request(method, url, headers={**headers, "Content-Type": "application/json"}, content=b"{not json"), label + " (garbage body)")
                seen += 1
    assert seen > 2500, seen


@pytest.mark.parametrize("query", ["page=0", "page=-3", "page=abc", "limit=0", "limit=100000", "limit=abc", "q=%00%27%22%3B--", "q=" + "a" * 5000, "sort=%27%3B", "status=zzz", "from=nope&to=nope"])
def test_hostile_query_strings_never_cause_a_5xx(client, callers, query):
    for (method, path, _), who in itertools.product([o for o in operations() if o[0] == "GET" and "{" not in o[1]], ["customer", "vendor", "admin", "anon"]):
        check(client.get(f"{path}?{query}", headers=callers[who]), f"{who} GET {path}?{query[:30]}")


def test_a_database_outage_is_a_clear_503_not_a_vague_502(client, callers, monkeypatch):
    def down(self, *a, **k):
        raise httpx.ConnectTimeout("simulated outage")
    import tests.conftest as c
    monkeypatch.setattr(c.FakeQuery, "execute", down)
    r = client.get("/api/v1/categories")
    assert r.status_code == 503 and r.json()["error"]["code"] == "service_unavailable"
    assert "timeout" not in r.text.lower() and "simulated" not in r.text.lower()           # internals are not echoed
    r = client.get("/api/v1/cart", headers=callers["customer"])
    assert r.status_code in (503, 401, 403)
