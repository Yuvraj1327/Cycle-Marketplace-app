"""Supabase client factories.

* admin client  - service-role key, bypasses RLS. Backend-only; never sent to any frontend.
* anon client   - anon key; subject to RLS. Use `with_user_token` to act on behalf of a signed-in user.
Clients are created lazily so the app (and /health) start even when Supabase is not configured.
"""
import logging
from functools import lru_cache

import httpx
from postgrest import SyncPostgrestClient
from supabase import Client, ClientOptions, create_client

from app.core.config import get_settings
from app.core.exceptions import ConfigurationError, ServiceUnavailableError


def _require(url: str, key: str, key_name: str) -> None:
    if not url or not key:
        raise ConfigurationError(f"SUPABASE_URL and {key_name} must be set.")


@lru_cache
def get_admin_client() -> Client:
    s = get_settings()
    _require(s.supabase_url, s.supabase_service_role_key, "SUPABASE_SERVICE_ROLE_KEY")
    return create_client(
        s.supabase_url,
        s.supabase_service_role_key,
        options=ClientOptions(auto_refresh_token=False, persist_session=False),
    )


@lru_cache
def get_anon_client() -> Client:
    s = get_settings()
    _require(s.supabase_url, s.supabase_anon_key, "SUPABASE_ANON_KEY")
    return create_client(
        s.supabase_url,
        s.supabase_anon_key,
        options=ClientOptions(auto_refresh_token=False, persist_session=False),
    )


def with_user_token(access_token: str) -> Client:
    """New short-lived client whose PostgREST calls run as the given user (RLS applies). Not cached."""
    s = get_settings()
    _require(s.supabase_url, s.supabase_anon_key, "SUPABASE_ANON_KEY")
    client = create_client(
        s.supabase_url,
        s.supabase_anon_key,
        options=ClientOptions(auto_refresh_token=False, persist_session=False),
    )
    client.postgrest.auth(access_token)
    return client


# ---------------------------------------------------------------------------
# Step 3 additions: user-scoped PostgREST access (RLS applies) and GoTrue logout
# ---------------------------------------------------------------------------


def create_user_db_client(access_token: str) -> SyncPostgrestClient:
    """PostgREST client that runs every query AS the signed-in user (anon key + the user's JWT).

    Postgres sees auth.uid() = the user, so the RLS policies and guard triggers from Step 2 apply.
    The service-role key is never used here. The caller must close it with `.aclose()`.
    """
    s = get_settings()
    _require(s.supabase_url, s.supabase_anon_key, "SUPABASE_ANON_KEY")
    return SyncPostgrestClient(
        f"{s.supabase_url.rstrip('/')}/rest/v1",
        headers={
            "apikey": s.supabase_anon_key,
            "Authorization": f"Bearer {access_token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )


def revoke_session(access_token: str, scope: str = "local") -> None:
    """Ask Supabase Auth (GoTrue) to end the session behind this access token."""
    s = get_settings()
    _require(s.supabase_url, s.supabase_anon_key, "SUPABASE_ANON_KEY")
    try:
        resp = httpx.post(
            f"{s.supabase_url.rstrip('/')}/auth/v1/logout",
            params={"scope": scope},
            headers={"apikey": s.supabase_anon_key, "Authorization": f"Bearer {access_token}"},
            timeout=10,
        )
    except httpx.HTTPError as exc:
        raise ServiceUnavailableError("Could not reach the authentication provider.") from exc
    # 204 = ended; 401/403/404 = session already gone/invalid - logout is idempotent
    if resp.status_code >= 500:
        raise ServiceUnavailableError("The authentication provider returned an error.")


# ---------------------------------------------------------------------------
# Step 4 additions: anonymous + service PostgREST clients, Storage helpers
# ---------------------------------------------------------------------------
logger = logging.getLogger(__name__)

_JSON = {"Accept": "application/json", "Content-Type": "application/json"}


def create_anon_db_client() -> SyncPostgrestClient:
    """PostgREST client for PUBLIC endpoints: anon key only, so RLS shows exactly what an anonymous visitor may see."""
    s = get_settings()
    _require(s.supabase_url, s.supabase_anon_key, "SUPABASE_ANON_KEY")
    return SyncPostgrestClient(
        f"{s.supabase_url.rstrip('/')}/rest/v1",
        headers={"apikey": s.supabase_anon_key, "Authorization": f"Bearer {s.supabase_anon_key}", **_JSON},
    )


def create_admin_db_client() -> SyncPostgrestClient:
    """SERVICE-ROLE PostgREST client (bypasses RLS). Server-side only; use solely for operations that genuinely need
    elevated rights (reading platform settings, auto-approving listings by policy, stock adjustment)."""
    s = get_settings()
    _require(s.supabase_url, s.supabase_service_role_key, "SUPABASE_SERVICE_ROLE_KEY")
    return SyncPostgrestClient(
        f"{s.supabase_url.rstrip('/')}/rest/v1",
        headers={"apikey": s.supabase_service_role_key, "Authorization": f"Bearer {s.supabase_service_role_key}", **_JSON},
    )


def public_storage_url(bucket: str, path: str) -> str:
    """URL of an object in a PUBLIC bucket (product-images, shop-images, banners)."""
    return f"{get_settings().supabase_url.rstrip('/')}/storage/v1/object/public/{bucket}/{path}"


def head_public_object(bucket: str, path: str) -> tuple[int, str, int] | None:
    """(status, content_type, size) for a public-bucket object, or None when it does not exist."""
    try:
        resp = httpx.head(public_storage_url(bucket, path), timeout=10, follow_redirects=True)
    except httpx.HTTPError as exc:
        raise ServiceUnavailableError("Could not reach Supabase Storage.") from exc
    if resp.status_code == 404 or resp.status_code == 400:
        return None
    if resp.status_code >= 400:
        raise ServiceUnavailableError("Supabase Storage returned an error.")
    return resp.status_code, resp.headers.get("content-type", "").split(";")[0].strip(), int(resp.headers.get("content-length", "0") or 0)


def delete_storage_object(access_token: str, bucket: str, path: str) -> None:
    """Delete one object AS THE USER (storage RLS decides). Missing objects count as deleted."""
    s = get_settings()
    _require(s.supabase_url, s.supabase_anon_key, "SUPABASE_ANON_KEY")
    try:
        resp = httpx.request(
            "DELETE",
            f"{s.supabase_url.rstrip('/')}/storage/v1/object/{bucket}/{path}",
            headers={"apikey": s.supabase_anon_key, "Authorization": f"Bearer {access_token}"},
            timeout=10,
        )
    except httpx.HTTPError as exc:
        raise ServiceUnavailableError("Could not reach Supabase Storage.") from exc
    if resp.status_code >= 500:
        raise ServiceUnavailableError("Supabase Storage returned an error.")
    if resp.status_code >= 400 and resp.status_code != 404:
        logger.warning("storage delete refused: %s %s", resp.status_code, path)


# ---------------------------------------------------------------------------
# Step 6: PRIVATE storage access performed AS THE USER (storage RLS from migration 09 decides who may see what)
# ---------------------------------------------------------------------------
def _storage_headers(access_token: str) -> dict[str, str]:
    s = get_settings()
    _require(s.supabase_url, s.supabase_anon_key, "SUPABASE_ANON_KEY")
    return {"apikey": s.supabase_anon_key, "Authorization": f"Bearer {access_token}"}


def private_object_info(access_token: str, bucket: str, path: str) -> tuple[str, int] | None:
    """(content_type, size) of an object the user may read, or None if it does not exist / is not readable by them."""
    s = get_settings()
    try:
        resp = httpx.head(f"{s.supabase_url.rstrip('/')}/storage/v1/object/{bucket}/{path}", headers=_storage_headers(access_token), timeout=10, follow_redirects=True)
    except httpx.HTTPError as exc:
        raise ServiceUnavailableError("Could not reach Supabase Storage.") from exc
    if resp.status_code in (400, 401, 403, 404):
        return None
    if resp.status_code >= 400:
        raise ServiceUnavailableError("Supabase Storage returned an error.")
    return resp.headers.get("content-type", "").split(";")[0].strip(), int(resp.headers.get("content-length", "0") or 0)


def create_signed_url(access_token: str, bucket: str, path: str, expires_in: int = 3600) -> str | None:
    """Time-limited URL for a private object. Signed AS THE USER, so storage RLS decides if they may; None when refused."""
    s = get_settings()
    try:
        resp = httpx.post(f"{s.supabase_url.rstrip('/')}/storage/v1/object/sign/{bucket}/{path}", json={"expiresIn": expires_in},
                          headers=_storage_headers(access_token), timeout=10)
    except httpx.HTTPError:
        return None
    if resp.status_code != 200:
        return None
    signed = resp.json().get("signedURL") or resp.json().get("signedUrl")
    return f"{s.supabase_url.rstrip('/')}/storage/v1{signed}" if signed and signed.startswith("/") else signed
