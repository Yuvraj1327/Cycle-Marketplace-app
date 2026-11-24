import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization

from app.core import security
from app.core.config import get_settings
from app.core.exceptions import InvalidTokenError, ServiceUnavailableError, TokenExpiredError

SUB = "11111111-1111-1111-1111-111111111111"


def test_valid_token(make_token):
    c = security.verify_access_token(make_token(SUB, extra={"phone": "919800000001"}))
    assert c.sub == SUB and c.phone == "919800000001" and c.session_id == "sess-1"


def test_expired_token(make_token):
    with pytest.raises(TokenExpiredError):
        security.verify_access_token(make_token(SUB, exp_in=-3600))


def test_bad_signature(make_token, other_private_key):
    with pytest.raises(InvalidTokenError):
        security.verify_access_token(make_token(SUB, key=other_private_key))


@pytest.mark.parametrize("kw", [{"iss": "https://evil.example/auth/v1"}, {"aud": "something-else"}, {"role": "anon"},
                                {"role": "service_role"}, {"drop": ("sub",)}, {"drop": ("exp",)}, {"drop": ("iss",)}])
def test_rejected_claims(make_token, kw):
    with pytest.raises(InvalidTokenError):
        security.verify_access_token(make_token(SUB, **kw))


def test_non_uuid_sub_is_not_rejected_here_but_garbage_is(make_token):
    for bad in ("", "abc", "a.b.c", "not-a-jwt"):
        with pytest.raises(InvalidTokenError):
            security.verify_access_token(bad)


def test_alg_none_rejected(make_token):
    with pytest.raises(InvalidTokenError):
        security.verify_access_token(make_token(SUB, alg="none"))


def test_hs256_rejected_unless_secret_configured(make_token, monkeypatch):
    token = jwt.encode({"sub": SUB, "aud": "authenticated", "iss": get_settings().jwt_issuer, "role": "authenticated",
                        "exp": int(time.time()) + 600}, "x" * 40, algorithm="HS256")
    with pytest.raises(InvalidTokenError):
        security.verify_access_token(token)
    monkeypatch.setenv("SUPABASE_JWT_SECRET", "x" * 40); get_settings.cache_clear()
    assert security.verify_access_token(token).sub == SUB
    monkeypatch.setenv("SUPABASE_JWT_SECRET", "y" * 40); get_settings.cache_clear()
    with pytest.raises(InvalidTokenError):
        security.verify_access_token(token)


def test_algorithm_confusion_attack_rejected(make_token, monkeypatch):
    """Attacker signs HS256 using the (public) RSA key bytes as the secret. Must fail in both configurations."""
    from tests.conftest import _PRIVATE
    pem = _PRIVATE.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    import base64
    import hashlib
    import hmac
    import json

    def b64(b: bytes) -> bytes:
        return base64.urlsafe_b64encode(b).rstrip(b"=")

    signing_input = b64(json.dumps({"alg": "HS256", "typ": "JWT", "kid": "k1"}).encode()) + b"." + b64(json.dumps({
        "sub": SUB, "aud": "authenticated", "iss": get_settings().jwt_issuer, "role": "authenticated",
        "exp": int(time.time()) + 600}).encode())
    forged = (signing_input + b"." + b64(hmac.new(pem, signing_input, hashlib.sha256).digest())).decode()
    with pytest.raises(InvalidTokenError):          # no HS256 secret configured
        security.verify_access_token(forged)
    monkeypatch.setenv("SUPABASE_JWT_SECRET", "z" * 40); get_settings.cache_clear()
    with pytest.raises(InvalidTokenError):          # secret configured, still wrong key
        security.verify_access_token(forged)


def test_jwks_unreachable_is_503_not_401(make_token, monkeypatch):
    from jwt.exceptions import PyJWKClientConnectionError

    class Down:
        def get_signing_key_from_jwt(self, _):
            raise PyJWKClientConnectionError("down")

    monkeypatch.setattr(security, "_jwks_client", lambda *a, **k: Down())
    with pytest.raises(ServiceUnavailableError):
        security.verify_access_token(make_token(SUB))
