from typing import Literal

from fastapi import APIRouter, Depends, Query, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E401, PROTECTED
from app.core.dependencies import CurrentUser, get_access_token, get_current_user, get_user_db
from app.repositories.vendor_repository import VendorRepository
from app.schemas.auth import MeResponse
from app.services.auth_service import AuthService

router = APIRouter(prefix="/auth", tags=["Auth"])


def get_auth_service(db: SyncPostgrestClient = Depends(get_user_db)) -> AuthService:
    return AuthService(VendorRepository(db))


@router.get(
    "/me",
    response_model=MeResponse,
    summary="Current user",
    description="**Protected** (any role, any account status). Verifies the bearer token and returns the "
    "identity, application role, account status and profile. The role comes from the database, never from the token.",
    responses=PROTECTED,
)
def me(user: CurrentUser = Depends(get_current_user), service: AuthService = Depends(get_auth_service)):
    return service.me(user)


@router.post(
    "/logout",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="End the Supabase session",
    description="**Protected.** Asks Supabase Auth to revoke the session behind this token (`scope=local` this "
    "device, `global` all devices, `others` all other devices). Access tokens are stateless JWTs and stay "
    "valid until they expire, so clients must also discard them.",
    responses=E401,
)
def logout(
    scope: Literal["local", "global", "others"] = Query("local"),
    token: str = Depends(get_access_token),
    _user: CurrentUser = Depends(get_current_user),
):
    AuthService.logout(token, scope)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
