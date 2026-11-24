"""Reusable authentication / authorization dependencies.

Chain:  Bearer token -> verified claims -> user-scoped DB client -> app profile (role/status from the DATABASE)
The role is read from public.profiles; JWT user_metadata / frontend-supplied roles are never trusted.
"""
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from typing import Any

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from postgrest import SyncPostgrestClient

from app.core.exceptions import AuthenticationError, NotFoundError, PermissionDeniedError
from app.core.security import TokenClaims, verify_access_token
from app.integrations.payments.registry import get_payment_provider
from app.integrations.supabase import create_admin_db_client, create_anon_db_client, create_user_db_client
from app.repositories.profile_repository import ProfileRepository
from app.repositories.vendor_repository import VendorRepository

bearer_scheme = HTTPBearer(
    auto_error=False,
    scheme_name="SupabaseJWT",
    description="Supabase Auth access token: `Authorization: Bearer <access_token>`",
)


@dataclass(frozen=True)
class CurrentUser:
    id: str
    role: str
    status: str
    email: str | None
    auth_phone: str | None  # phone verified by Supabase Auth (from the token), if any
    profile: dict[str, Any] = field(repr=False)
    claims: TokenClaims = field(repr=False)
    access_token: str = field(default="", repr=False)  # forwarded to Storage calls made on the user's behalf


@dataclass(frozen=True)
class ApprovedVendor:
    user: CurrentUser
    vendor: dict[str, Any]


def get_access_token(credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme)) -> str:
    if credentials is None or credentials.scheme.lower() != "bearer" or not credentials.credentials:
        raise AuthenticationError()
    return credentials.credentials


def get_token_claims(token: str = Depends(get_access_token)) -> TokenClaims:
    return verify_access_token(token)


def get_user_db(
    token: str = Depends(get_access_token),
    _claims: TokenClaims = Depends(get_token_claims),  # forces verification before any DB client exists
) -> Iterator[SyncPostgrestClient]:
    """PostgREST client acting as the caller, so RLS and guard triggers apply. Closed after the request."""
    client = create_user_db_client(token)
    try:
        yield client
    finally:
        client.aclose()


def get_public_db() -> Iterator[SyncPostgrestClient]:
    """Anonymous (anon-key) client for public endpoints. RLS limits it to publicly visible rows."""
    client = create_anon_db_client()
    try:
        yield client
    finally:
        client.aclose()


def get_admin_db() -> Iterator[SyncPostgrestClient]:
    """Service-role client. Only for server-side logic that needs elevated rights; never reachable from request data."""
    client = create_admin_db_client()
    try:
        yield client
    finally:
        client.aclose()


def get_provider():
    """The configured payment provider adapter (or an 'unconfigured' stand-in that refuses to simulate payments)."""
    return get_payment_provider()


def get_current_user(
    claims: TokenClaims = Depends(get_token_claims),
    db: SyncPostgrestClient = Depends(get_user_db),
    token: str = Depends(get_access_token),
) -> CurrentUser:
    try:
        profile = ProfileRepository(db).get(claims.sub)
    except NotFoundError as exc:
        raise PermissionDeniedError("No application profile exists for this account.") from exc
    return CurrentUser(
        id=profile["id"],
        role=profile["role"],
        status=profile["status"],
        email=profile.get("email") or claims.email,
        auth_phone=claims.phone,
        profile=profile,
        claims=claims,
        access_token=token,
    )


def get_current_active_user(user: CurrentUser = Depends(get_current_user)) -> CurrentUser:
    if user.status != "active":
        err = PermissionDeniedError(f"This account is {user.status}.")
        err.code = f"account_{user.status}"
        raise err
    return user


def require_role(*roles: str) -> Callable[..., CurrentUser]:
    allowed = frozenset(roles)

    def checker(user: CurrentUser = Depends(get_current_active_user)) -> CurrentUser:
        if user.role not in allowed:
            raise PermissionDeniedError("Your role is not allowed to perform this action.")
        return user

    return checker


require_customer = require_role("customer")
require_vendor = require_role("vendor")
require_admin = require_role("admin")


def require_approved_vendor(
    user: CurrentUser = Depends(require_vendor),
    db: SyncPostgrestClient = Depends(get_user_db),
) -> ApprovedVendor:
    """For vendor operations that need an approved business (products, orders, ... in later steps)."""
    vendor = VendorRepository(db).find_by_user(user.id)
    if vendor is None:
        err = PermissionDeniedError("Complete vendor registration first.")
        err.code = "vendor_not_registered"
        raise err
    if vendor["verification_status"] != "approved":
        err = PermissionDeniedError(f"Vendor account is {vendor['verification_status']}.")
        err.code = f"vendor_{vendor['verification_status']}"
        raise err
    return ApprovedVendor(user=user, vendor=vendor)
