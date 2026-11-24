from fastapi import APIRouter, Depends, Response
from postgrest import SyncPostgrestClient

from app.core.dependencies import get_public_db
from app.repositories.banner_repository import BannerRepository
from app.schemas.banner import BannerOut
from app.services.banner_service import BannerService

router = APIRouter(prefix="/banners", tags=["Banners"])


@router.get("", response_model=list[BannerOut], summary="Active promotional banners",
            description="**Public.** Active banners inside their display window, ordered by `sort_order`.")
def list_banners(response: Response, db: SyncPostgrestClient = Depends(get_public_db)):
    response.headers["Cache-Control"] = "public, max-age=60"
    return BannerService(BannerRepository(db)).public_list()
