from fastapi import APIRouter, Depends, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_user_db, require_vendor
from app.repositories.vendor_repository import VendorRepository
from app.schemas.vendor import VendorProfileResponse, VendorRegister, VendorStatusResponse, VendorUpdate
from app.services.vendor_service import VendorService

router = APIRouter(prefix="/vendors", tags=["Vendors"], responses=PROTECTED)


def get_vendor_service(db: SyncPostgrestClient = Depends(get_user_db)) -> VendorService:
    return VendorService(VendorRepository(db))


@router.post(
    "/register", response_model=VendorProfileResponse, status_code=status.HTTP_201_CREATED,
    summary="Submit vendor application",
    description="**Protected - vendor role** (account created through Supabase Auth with vendor sign-up). "
    "Creates the business profile with `verification_status = pending`. Registering grants no vendor privileges "
    "until an administrator approves the application. One application per account.",
    responses={**E409, **E422},
)
def register_vendor(body: VendorRegister, user: CurrentUser = Depends(require_vendor), service: VendorService = Depends(get_vendor_service)):
    return service.register(user, body)


@router.get(
    "/me", response_model=VendorProfileResponse, summary="Get own vendor profile",
    description="**Protected - vendor role.** Available in every verification state.", responses=E404,
)
def get_my_vendor_profile(user: CurrentUser = Depends(require_vendor), service: VendorService = Depends(get_vendor_service)):
    return service.get_own(user)


@router.put(
    "/me", response_model=VendorProfileResponse, summary="Update own business information",
    description="**Protected - vendor role.** Partial update. Verification fields cannot be sent (422). "
    "Suspended vendors are refused (403 `vendor_suspended`).",
    responses={**E400, **E404, **E422},
)
def update_my_vendor_profile(body: VendorUpdate, user: CurrentUser = Depends(require_vendor), service: VendorService = Depends(get_vendor_service)):
    return service.update_own(user, body)


@router.get(
    "/me/status", response_model=VendorStatusResponse, summary="Own verification status",
    description="**Protected - vendor role.** `can_operate` is true only for approved vendors.", responses=E404,
)
def get_my_vendor_status(user: CurrentUser = Depends(require_vendor), service: VendorService = Depends(get_vendor_service)):
    return service.status(user)
