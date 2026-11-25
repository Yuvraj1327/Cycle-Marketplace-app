"""FCM adapter against a MOCKED HTTP transport (httpx.MockTransport). This verifies our request building, OAuth handling and error mapping.
It does NOT prove delivery through a real Firebase project - none is available in this environment."""
import json
import logging

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app.core.config import Settings
from app.integrations.push.base import PushMessage, UnconfiguredPush
from app.integrations.push.fcm import FcmProvider, build_fcm, load_service_account
from app.integrations.push.registry import get_push_provider

_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PRIVATE_PEM = _KEY.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
PUBLIC = _KEY.public_key()
ACCOUNT = {"type": "service_account", "project_id": "cycle-demo", "client_email": "push@cycle-demo.iam.gserviceaccount.com", "private_key": PRIVATE_PEM, "token_uri": "https://oauth2.googleapis.com/token"}
MSG = PushMessage(title="Order accepted", body="Order ORD-1 is accepted.", data={"related_type": "order", "related_id": "abc", "notification_id": "n1"})


class Fcm:
    """A scripted Google: OAuth endpoint + FCM send endpoint."""

    def __init__(self, send_responses=None):
        self.requests: list[httpx.Request] = []
        self.sends = list(send_responses or [(200, {"name": "projects/x/messages/1"})])
        self.oauth_calls = 0

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if request.url.host == "oauth2.googleapis.com":
            self.oauth_calls += 1
            return httpx.Response(200, json={"access_token": f"ya29.token-{self.oauth_calls}", "expires_in": 3600})
        code, body = self.sends.pop(0) if len(self.sends) > 1 else self.sends[0]
        return httpx.Response(code, json=body)


def provider(fcm: Fcm, clock=lambda: 1_000_000.0) -> FcmProvider:
    return FcmProvider(project_id="cycle-demo", client_email=ACCOUNT["client_email"], private_key=PRIVATE_PEM, http=httpx.Client(transport=httpx.MockTransport(fcm)), clock=clock)


def error(code, status, **extra):
    return (code, {"error": {"code": code, "status": status, "message": extra.pop("message", "boom"), **extra}})


def test_sends_the_documented_v1_request_with_a_signed_oauth_assertion():
    fcm = Fcm()
    res = provider(fcm).send("device-token-1234567890", MSG)
    assert res.status == "sent"
    oauth, send = fcm.requests
    form = dict(x.split("=", 1) for x in oauth.content.decode().split("&"))
    claims = jwt.decode(form["assertion"].replace("%2E", "."), PUBLIC, algorithms=["RS256"], audience="https://oauth2.googleapis.com/token", options={"verify_exp": False})
    assert claims["iss"] == ACCOUNT["client_email"] and claims["scope"] == "https://www.googleapis.com/auth/firebase.messaging"
    assert form["grant_type"].startswith("urn%3Aietf")
    assert str(send.url) == "https://fcm.googleapis.com/v1/projects/cycle-demo/messages:send"
    assert send.headers["authorization"] == "Bearer ya29.token-1"
    body = json.loads(send.content)["message"]
    assert body["token"] == "device-token-1234567890" and body["notification"] == {"title": "Order accepted", "body": "Order ORD-1 is accepted."}
    assert body["data"] == {"related_type": "order", "related_id": "abc", "notification_id": "n1"} and body["android"]["priority"] == "HIGH"


def test_the_oauth_token_is_cached_and_renewed_when_it_nears_expiry_or_is_refused():
    now = [1_000_000.0]
    fcm = Fcm()
    p = provider(fcm, clock=lambda: now[0])
    for _ in range(3):
        assert p.send("device-token-1234567890", MSG).status == "sent"
    assert fcm.oauth_calls == 1
    now[0] += 3600                                                                  # expired
    p.send("device-token-1234567890", MSG)
    assert fcm.oauth_calls == 2
    fcm2 = Fcm([error(401, "UNAUTHENTICATED"), (200, {})])                         # FCM says the token is bad: fetch a new one once, then succeed
    assert provider(fcm2).send("device-token-1234567890", MSG).status == "sent" and fcm2.oauth_calls == 2


@pytest.mark.parametrize("responses,expected", [
    ([error(404, "NOT_FOUND", details=[{"errorCode": "UNREGISTERED"}])], "invalid_token"),
    ([error(400, "INVALID_ARGUMENT", message="The registration token is not a valid FCM registration token")], "invalid_token"),
    ([error(403, "PERMISSION_DENIED", details=[{"errorCode": "SENDER_ID_MISMATCH"}])], "invalid_token"),
    ([error(400, "INVALID_ARGUMENT", message="Invalid JSON payload received")], "failed"),
    ([error(429, "RESOURCE_EXHAUSTED", details=[{"errorCode": "QUOTA_EXCEEDED"}])], "retry"),
    ([error(503, "UNAVAILABLE")], "retry"),
    ([error(500, "INTERNAL")], "retry"),
    ([error(403, "PERMISSION_DENIED")], "failed"),
])
def test_errors_are_classified_so_bad_tokens_are_dropped_and_outages_are_retried(responses, expected):
    assert provider(Fcm(responses)).send("device-token-1234567890", MSG).status == expected


def test_network_failure_is_a_retry_not_a_crash_and_leaks_nothing():
    def boom(request):
        raise httpx.ConnectError("connection refused", request=request)
    p = FcmProvider(project_id="cycle-demo", client_email=ACCOUNT["client_email"], private_key=PRIVATE_PEM, http=httpx.Client(transport=httpx.MockTransport(boom)))
    res = p.send("device-token-1234567890", MSG)
    assert res.status == "retry" and "device-token" not in res.detail and "BEGIN" not in res.detail


def test_credentials_load_from_inline_json_or_file_and_incomplete_ones_disable_push(tmp_path, caplog):
    inline = Settings(fcm_service_account_json=json.dumps(ACCOUNT))
    assert load_service_account(inline)["client_email"] == ACCOUNT["client_email"]
    f = tmp_path / "sa.json"
    f.write_text(json.dumps(ACCOUNT))
    assert build_fcm(Settings(fcm_service_account_file=str(f))).is_configured() and build_fcm(Settings(fcm_service_account_file=str(f))).project_id == "cycle-demo"
    assert build_fcm(Settings(fcm_service_account_file=str(f), fcm_project_id="override")).project_id == "override"
    assert build_fcm(Settings()) is None                                                               # nothing configured
    with caplog.at_level(logging.ERROR):
        assert build_fcm(Settings(fcm_service_account_json=json.dumps({"client_email": "x@y"}))) is None  # key missing
        assert build_fcm(Settings(fcm_service_account_json="{not json")) is None
        assert build_fcm(Settings(fcm_service_account_file=str(tmp_path / "missing.json"))) is None
    assert "BEGIN PRIVATE KEY" not in caplog.text and PRIVATE_PEM[40:80] not in caplog.text            # credentials are never logged


def test_without_credentials_the_registry_gives_an_unconfigured_provider(monkeypatch):
    monkeypatch.delenv("FCM_SERVICE_ACCOUNT_JSON", raising=False)
    from app.core.config import get_settings
    get_settings.cache_clear()
    try:
        p = get_push_provider()
        assert isinstance(p, UnconfiguredPush) and not p.is_configured()
    finally:
        get_settings.cache_clear()
