"""Verification of Supabase Auth access tokens. FastAPI never issues tokens and never sees passwords.

Key selection (never trusts the token to choose a weaker scheme):
  * alg HS256            -> legacy shared secret (SUPABASE_JWT_SECRET); only if configured
  * alg RS256/ES256/EdDSA -> public key from the project's JWKS endpoint, selected by `kid`
  * anything else (incl. "none") -> rejected
`algorithms=[alg]` is passed to PyJWT per key family, so a token signed HS256 with a public key as the
"secret" cannot be verified against the JWKS path (algorithm-confusion attack).
"""
from functools import lru_cache
from typing import Any

import jwt
from jwt import PyJWKClient
from jwt.exceptions import PyJWKClientConnectionError, PyJWKClientError
from pydantic import BaseModel

from app.core.config import Settings, get_settings
from app.core.exceptions import (
    ConfigurationError,
    InvalidTokenError,
    ServiceUnavailableError,
    TokenExpiredError,
)

SYMMETRIC_ALGS = {"HS256"}
ASYMMETRIC_ALGS = {"RS256", "ES256", "EdDSA"}


class TokenClaims(BaseModel):
    """Verified claims we are willing to rely on. `role` here is Supabase's 'authenticated', NOT the app role."""

    sub: str
    email: str | None = None
    phone: str | None = None
    session_id: str | None = None
    aal: str | None = None
    exp: int


@lru_cache
def _jwks_client(jwks_url: str, lifespan: int) -> PyJWKClient:
    return PyJWKClient(jwks_url, cache_keys=True, lifespan=lifespan, timeout=5)


def _signing_key(token: str, alg: str, settings: Settings) -> Any:
    if alg in SYMMETRIC_ALGS:
        if not settings.supabase_jwt_secret:
            raise InvalidTokenError()  # HS256 token but this deployment only trusts asymmetric keys
        return settings.supabase_jwt_secret
    if alg in ASYMMETRIC_ALGS:
        try:
            client = _jwks_client(settings.jwks_url, settings.jwks_cache_seconds)
            return client.get_signing_key_from_jwt(token).key
        except PyJWKClientConnectionError as exc:
            raise ServiceUnavailableError("Could not reach the authentication provider.") from exc
        except PyJWKClientError as exc:  # unknown kid, malformed JWKS entry, ...
            raise InvalidTokenError() from exc
    raise InvalidTokenError()


def verify_access_token(token: str) -> TokenClaims:
    settings = get_settings()
    if not settings.supabase_url:
        raise ConfigurationError("SUPABASE_URL is not configured.")
    try:
        alg = jwt.get_unverified_header(token).get("alg", "")
    except jwt.PyJWTError as exc:
        raise InvalidTokenError() from exc

    key = _signing_key(token, alg, settings)
    try:
        payload = jwt.decode(
            token,
            key,
            algorithms=[alg],
            audience=settings.jwt_audience,
            issuer=settings.jwt_issuer,
            leeway=settings.jwt_leeway_seconds,
            options={"require": ["exp", "sub", "aud", "iss"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise TokenExpiredError() from exc
    except jwt.PyJWTError as exc:
        raise InvalidTokenError() from exc

    # Anonymous / service tokens (role=anon|service_role) must never authenticate a user.
    if payload.get("role") != "authenticated":
        raise InvalidTokenError()
    try:
        return TokenClaims(
            sub=payload["sub"],
            email=payload.get("email") or None,
            phone=payload.get("phone") or None,
            session_id=payload.get("session_id"),
            aal=payload.get("aal"),
            exp=payload["exp"],
        )
    except ValueError as exc:
        raise InvalidTokenError() from exc
