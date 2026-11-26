"""Device registration, the push outbox dispatcher and the admin push endpoints. The push PROVIDER is a scripted fake: this proves our logic (ownership,
no duplicates, retries, independence from the business transaction), not delivery through real Firebase."""
import uuid

import pytest

from app.api.v1.endpoints.devices import get_provider_dep
from app.integrations.push.base import PushResult, UnconfiguredPush
from app.main import app

D = "/api/v1/devices"
A = "/api/v1/admin/push"
T1, T2, T3 = ("fcm-token-%s-abcdefghijklmnopqrst" % c for c in "123")


class FakePush:
    name = "fcm"

    def __init__(self):
        self.sent, self.script, self.configured = [], {}, True

    def is_configured(self):
        return self.configured

    def send(self, token, message):
        self.sent.append((token, message))
        steps = self.script.get(token)
        r = steps.pop(0) if steps else PushResult("sent")
        if isinstance(r, Exception):
            raise r
        return r


@pytest.fixture
def push():
    p = FakePush()
    app.dependency_overrides[get_provider_dep] = lambda: p
    yield p
    app.dependency_overrides.pop(get_provider_dep, None)


def reg(client, headers, token=T1, app_="customer", **kw):
    return client.put(D, json={"token": token, "platform": "android", "app": app_, **kw}, headers=headers)


def dispatch(client, world):
    r = client.post(f"{A}/dispatch", headers=world.ha)
    assert r.status_code == 200, r.text
    return r.json()


def rows(world, **kw):
    return [n for n in world.db.rows("notifications") if all(n.get(k) == v for k, v in kw.items())]


# ------------------------------------------------------------------------------------------------ registration
def test_only_signed_in_customers_and_vendors_can_register_and_the_app_must_match_the_role(client, world):
    assert reg(client, {}).status_code == 401
    assert reg(client, world.ha, app_="customer").status_code == 403                    # admins have no push app
    assert reg(client, world.h, app_="vendor").status_code == 403                       # a customer cannot register as the vendor app
    assert reg(client, world.hva, app_="customer").status_code == 403
    assert reg(client, world.h).json() == {"registered": True}
    assert reg(client, world.hva, token=T2, app_="vendor").json() == {"registered": True}
    world.db.profile(world.cust)["status"] = "inactive"
    assert reg(client, world.h, token=T3).status_code == 403                            # inactive accounts are refused
    assert {t["token"] for t in world.db.rows("device_tokens")} == {T1, T2}


def test_validation_unknown_fields_and_tokens_are_never_returned(client, world):
    for body in ({"token": "short", "platform": "android", "app": "customer"}, {"token": T1, "platform": "symbian", "app": "customer"}, {"token": T1, "platform": "android", "app": "admin"},
                 {"token": T1, "platform": "android", "app": "customer", "user_id": world.other}, {"token": T1, "platform": "android", "app": "customer", "is_active": False}):
        assert client.put(D, json=body, headers=world.h).status_code == 422, body
    r = reg(client, world.h, device_label="Pixel 7", app_version="1.0.0")
    assert T1 not in r.text and set(r.json()) == {"registered"}
    assert client.get(D, headers=world.h).status_code in (404, 405)                    # there is no way to list or read tokens
    assert world.db.rows("device_tokens")[0]["user_id"] == world.cust


def test_registering_is_idempotent_and_a_token_moves_to_whoever_signs_in_on_that_phone(client, world):
    for _ in range(3):
        reg(client, world.h)
    assert len(world.db.rows("device_tokens")) == 1
    other_customer = reg(client, world.hother)                                          # same phone, a different customer account
    assert other_customer.status_code == 200
    (row,) = world.db.rows("device_tokens")
    assert row["user_id"] == world.other and row["is_active"]
    assert reg(client, world.h, token=T2).status_code == 200                           # a user can have several devices
    assert len([t for t in world.db.rows("device_tokens") if t["user_id"] == world.cust and t["is_active"]]) == 1


def test_a_user_keeps_at_most_ten_active_devices(client, world):
    for i in range(14):
        reg(client, world.h, token=f"fcm-device-{i:03d}-abcdefghijklmnopqrst")
    assert len([t for t in world.db.rows("device_tokens") if t["is_active"]]) == 10


def test_unregister_only_works_for_the_owner(client, world):
    reg(client, world.h)
    assert client.post(f"{D}/unregister", json={"token": T1}, headers=world.hother).json() == {"unregistered": False}
    assert world.db.rows("device_tokens")[0]["is_active"]
    assert client.post(f"{D}/unregister", json={"token": T1}, headers=world.h).json() == {"unregistered": True}
    assert not world.db.rows("device_tokens")[0]["is_active"]
    assert client.post(f"{D}/unregister", json={"token": T1}, headers=world.h).json() == {"unregistered": False}
    assert client.post(f"{D}/unregister", json={"token": T1}).status_code == 401


# ------------------------------------------------------------------------------------------------ dispatcher
def place_cod_order(world):
    world.add(world.bike)
    assert world.checkout().status_code == 201


def test_a_business_event_creates_pending_notifications_and_dispatch_sends_each_exactly_once(client, world, push):
    reg(client, world.h)
    reg(client, world.hva, token=T2, app_="vendor")
    place_cod_order(world)
    pending = rows(world, push_status="pending")
    assert {(n["user_id"], n["title"]) for n in pending} == {(world.cust, "Order placed"), (world.ua, "New order")}
    out = dispatch(client, world)
    assert out == {"configured": True, "claimed": 2, "sent": 2, "retry": 0, "failed": 0, "skipped": 0}
    assert {t for t, _ in push.sent} == {T1, T2} and all(n["push_status"] == "sent" for n in pending)
    again = dispatch(client, world)
    assert again["claimed"] == 0 and len(push.sent) == 2, "a second dispatch (or a second worker) sends nothing again"


def test_the_push_carries_only_the_text_and_record_ids(client, world, push):
    reg(client, world.h)
    place_cod_order(world)
    dispatch(client, world)
    token, msg = push.sent[0]
    order = world.db.rows("orders")[0]
    assert token == T1 and msg.title == "Order placed"
    assert msg.data == {"notification_id": rows(world, user_id=world.cust)[0]["id"], "type": "order", "related_type": "order", "related_id": order["id"]}
    assert all(isinstance(v, str) for v in msg.data.values()) and "address" not in str(msg.data).lower() and world.addr["address_line1"] not in str(msg)


def test_long_notification_text_is_truncated_for_the_device_but_stays_complete_in_app(client, world, push):
    reg(client, world.h)
    world.db.rows("notifications").append(world.db.apply_defaults("notifications", {"user_id": world.cust, "type": "system", "title": "T" * 300, "message": "m" * 500}))
    dispatch(client, world)
    msg = push.sent[0][1]
    assert len(msg.title) == 100 and len(msg.body) == 180 and msg.body.endswith("…")
    assert len(client.get("/api/v1/notifications", headers=world.h).json()["items"][0]["message"]) == 500


def test_a_user_without_a_device_is_skipped_and_an_inactive_account_is_never_pushed(client, world, push):
    place_cod_order(world)
    reg(client, world.hva, token=T2, app_="vendor")
    world.db.profile(world.cust)["status"] = "inactive"
    out = dispatch(client, world)
    assert out["sent"] == 1 and [t for t, _ in push.sent] == [T2]
    assert {n["push_status"] for n in rows(world, user_id=world.cust)} == {"skipped"}


def test_a_provider_outage_leaves_the_business_data_alone_and_retries_with_backoff(client, world, push):
    reg(client, world.h)
    push.script[T1] = [PushResult("retry", "FCM temporarily unavailable (503)")]
    place_cod_order(world)                                                              # the order is created although push is failing
    assert world.db.rows("orders")[0]["status"] == "confirmed"
    out = dispatch(client, world)
    assert out["retry"] == 1
    n = rows(world, user_id=world.cust)[0]
    assert n["push_status"] == "pending" and n["push_attempts"] == 1 and "503" in n["push_error"] and n["push_next_at"]
    assert dispatch(client, world)["claimed"] == 0, "not retried before its back-off has passed"
    n["push_next_at"] = None
    assert dispatch(client, world)["sent"] == 1 and n["push_status"] == "sent" and n["push_attempts"] == 2
    assert [t for t, _ in push.sent].count(T1) == 2


def test_repeated_failures_end_as_failed_and_are_visible_to_the_admin(client, world, push):
    reg(client, world.h)
    push.script[T1] = [PushResult("retry", "FCM unavailable")] * 10
    place_cod_order(world)
    for _ in range(6):
        for n in world.db.rows("notifications"):
            n["push_next_at"] = None
        dispatch(client, world)
    n = rows(world, user_id=world.cust)[0]
    assert n["push_status"] == "failed" and n["push_attempts"] == 5
    s = client.get(f"{A}/status", headers=world.ha).json()
    assert s["by_status"].get("failed") == 1 and s["recent_failures"][0]["title"] == "Order placed" and T1 not in str(s)


def test_invalid_tokens_are_deactivated_and_the_other_devices_still_receive_it(client, world, push):
    reg(client, world.h)
    reg(client, world.h, token=T2)
    push.script[T1] = [PushResult("invalid_token", "token is no longer registered")]
    place_cod_order(world)
    out = dispatch(client, world)
    assert out["sent"] >= 1
    tokens = {t["token"]: t for t in world.db.rows("device_tokens")}
    assert tokens[T1]["is_active"] is False and tokens[T2]["is_active"] is True
    assert rows(world, user_id=world.cust)[0]["push_status"] == "sent"


def test_when_every_device_is_invalid_the_notification_is_skipped_not_retried_forever(client, world, push):
    reg(client, world.h)
    push.script[T1] = [PushResult("invalid_token")]
    place_cod_order(world)
    dispatch(client, world)
    assert rows(world, user_id=world.cust)[0]["push_status"] == "skipped" and not world.db.rows("device_tokens")[0]["is_active"]


def test_a_crashing_provider_does_not_lose_the_rest_of_the_batch(client, world, push):
    reg(client, world.h)
    reg(client, world.hva, token=T2, app_="vendor")
    push.script[T1] = [RuntimeError("adapter bug")]
    place_cod_order(world)
    out = dispatch(client, world)
    assert out["retry"] == 1 and out["sent"] == 1
    assert rows(world, user_id=world.ua)[0]["push_status"] == "sent"


def test_without_a_configured_provider_nothing_is_sent_or_claimed_and_the_status_says_so(client, world, push):
    push.configured = False
    reg(client, world.h)
    place_cod_order(world)
    out = dispatch(client, world)
    assert out == {"configured": False, "claimed": 0, "sent": 0, "retry": 0, "failed": 0, "skipped": 0} and push.sent == []
    assert {n["push_status"] for n in rows(world, user_id=world.cust)} == {"pending"}
    s = client.get(f"{A}/status", headers=world.ha).json()
    assert s["configured"] is False and s["provider"] is None and s["dispatcher_enabled"] is False and s["active_devices"] == {"customer": 1}
    assert len(client.get("/api/v1/notifications", headers=world.h).json()["items"]) == 1, "the in-app notification exists regardless"


def test_old_pending_notifications_expire_instead_of_arriving_late(client, world, push):
    reg(client, world.h)
    place_cod_order(world)
    for n in world.db.rows("notifications"):
        n["created_at"] = "2025-12-01T00:00:00+00:00"
    out = dispatch(client, world)
    assert out["claimed"] == 0 and push.sent == [] and {n["push_status"] for n in world.db.rows("notifications")} == {"expired"}


def test_the_default_provider_is_unconfigured_so_the_real_app_never_pretends(client, world):
    app.dependency_overrides.pop(get_provider_dep, None)
    r = client.get(f"{A}/status", headers=world.ha).json()
    assert r["configured"] is False
    assert dispatch(client, world)["configured"] is False


def test_push_admin_endpoints_are_admin_only(client, world):
    for headers, expected in (({}, 401), (world.h, 403), (world.hva, 403)):
        assert client.get(f"{A}/status", headers=headers).status_code == expected
        assert client.post(f"{A}/dispatch", headers=headers).status_code == expected


def test_announcements_are_pushed_and_their_history_reports_the_push_outcome(client, world, push):
    reg(client, world.h)
    a = client.post("/api/v1/admin/announcements", json={"title": "Festive sale", "message": "Up to 20% off.", "type": "promotion", "audience": "customers"}, headers=world.ha).json()
    assert (a["delivered"], a["push_pending"], a["push_sent"]) == (2, 2, 0)
    dispatch(client, world)
    h = client.get("/api/v1/admin/announcements", headers=world.ha).json()["items"][0]
    assert (h["push_sent"], h["push_pending"], h["push_failed"]) == (1, 0, 0)                  # the second customer has no device: skipped, not failed
    assert push.sent[0][1].data["type"] == "promotion" and "related_id" not in push.sent[0][1].data
    rec = client.get("/api/v1/admin/notifications", headers=world.ha).json()["items"]
    assert {r["push_status"] for r in rec} == {"sent", "skipped"}


# ------------------------------------------------------------------------------------------------ secrets and CORS
def test_configured_credentials_never_appear_in_any_response_or_log(client, world, monkeypatch, caplog):
    import json
    import logging

    from tests.test_push_fcm_adapter import ACCOUNT
    from app.core.config import get_settings
    secret_markers = [ACCOUNT["private_key"][40:100], ACCOUNT["client_email"], "sk_live_SUPERSECRET", "whsec_SUPERSECRET"]
    monkeypatch.setenv("FCM_SERVICE_ACCOUNT_JSON", json.dumps(ACCOUNT))
    monkeypatch.setenv("PAYMENT_PROVIDER_KEY_SECRET", "sk_live_SUPERSECRET")
    monkeypatch.setenv("PAYMENT_WEBHOOK_SECRET", "whsec_SUPERSECRET")
    get_settings.cache_clear()
    app.dependency_overrides.pop(get_provider_dep, None)
    try:
        with caplog.at_level(logging.DEBUG):
            bodies = [client.get(f"{A}/status", headers=world.ha), client.post(f"{A}/dispatch", headers=world.ha), client.get("/api/v1/admin/payments/provider", headers=world.ha),
                      client.get("/api/v1/admin/settings", headers=world.ha), client.get("/health/config"), client.get("/openapi.json")]
        status = bodies[0].json()
        assert status["configured"] is True and status["provider"] == "fcm"                  # configured, and the answer says only that
        for r in bodies:
            for marker in secret_markers:
                assert marker not in r.text, (r.request.url, marker)
        assert not any(m in caplog.text for m in secret_markers)
    finally:
        get_settings.cache_clear()


def test_cors_allows_only_the_configured_origin(client):
    from app.core.config import get_settings
    allowed = get_settings().cors_origins
    assert "*" not in allowed
    origin = allowed[0]
    ok = client.options("/api/v1/auth/me", headers={"Origin": origin, "Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "authorization"})
    assert ok.status_code == 200 and ok.headers.get("access-control-allow-origin") == origin
    assert "authorization" in ok.headers.get("access-control-allow-headers", "").lower()
    for evil in ("https://evil.example", "http://localhost:5999", "null"):
        r = client.options("/api/v1/auth/me", headers={"Origin": evil, "Access-Control-Request-Method": "GET"})
        assert "access-control-allow-origin" not in r.headers, evil


def test_cors_origin_parsing_accepts_json_or_comma_separated_and_refuses_wildcard():
    import pytest

    from app.core.config import parse_origins
    assert parse_origins('["http://localhost:5174/", "https://admin.example.com"]') == ["http://localhost:5174", "https://admin.example.com"]
    assert parse_origins("http://localhost:5174, https://admin.example.com/") == ["http://localhost:5174", "https://admin.example.com"]
    with pytest.raises(ValueError):
        parse_origins("*")


def test_cors_origin_regex_is_opt_in_and_still_rejects_other_hosts(monkeypatch):
    from fastapi import FastAPI
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.testclient import TestClient
    app = FastAPI()
    app.add_middleware(CORSMiddleware, allow_origins=[], allow_origin_regex=r"^http://(localhost|127\.0\.0\.1)(:[0-9]+)?$", allow_methods=["GET"], allow_headers=["Authorization"])
    c = TestClient(app)
    hdrs = {"Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "authorization"}
    assert c.options("/x", headers={"Origin": "http://localhost:59582", **hdrs}).headers.get("access-control-allow-origin") == "http://localhost:59582"
    for evil in ("https://evil.example", "http://localhost.evil.example", "https://localhost:1"):
        assert "access-control-allow-origin" not in c.options("/x", headers={"Origin": evil, **hdrs}).headers, evil
