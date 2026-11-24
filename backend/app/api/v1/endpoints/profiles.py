from fastapi import APIRouter, Depends
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_current_active_user, get_current_user, get_user_db
from app.repositories.profile_repository import ProfileRepository
from app.schemas.profile import ProfileResponse, ProfileUpdate
from app.services.profile_service import ProfileService

router = APIRouter(prefix="/profiles", tags=["Profiles"])


def get_profile_service(db: SyncPostgrestClient = Depends(get_user_db)) -> ProfileService:
    return ProfileService(ProfileRepository(db))


@router.get(
    "/me",
    response_model=ProfileResponse,
    summary="Get own profile",
    description="**Protected** (any role). Returns the caller's own profile only.",
    responses=PROTECTED,
)
def get_my_profile(user: CurrentUser = Depends(get_current_user), service: ProfileService = Depends(get_profile_service)):
    return service.get_own(user)


@router.put(
    "/me",
    response_model=ProfileResponse,
    summary="Update own profile",
    description="**Protected** (active accounts). Partial update: only the supplied fields change. Editable: "
    "`full_name`, `phone` (not when the phone is a verified sign-in identifier), `avatar_path` (must be inside "
    "your own storage folder). `role`, `status` and `email` are rejected with 422.",
    responses={**PROTECTED, **E400, **E409, **E422},
)
def update_my_profile(
    body: ProfileUpdate,
    user: CurrentUser = Depends(get_current_active_user),
    service: ProfileService = Depends(get_profile_service),
):
    return service.update_own(user, body)
