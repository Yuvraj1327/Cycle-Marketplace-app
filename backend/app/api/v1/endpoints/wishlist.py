from uuid import UUID

from fastapi import APIRouter, Depends, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_user_db, require_customer
from app.schemas.cart import WishlistAdd, WishlistItemOut, WishlistOut
from app.services.wishlist_service import WishlistService

router = APIRouter(prefix="/wishlist", tags=["Wishlist"], responses=PROTECTED)
_NOTE = "**Protected - customer role.** Your own wishlist only; nobody else can read it."


def get_service(db: SyncPostgrestClient = Depends(get_user_db)) -> WishlistService:
    return WishlistService(db)


@router.get("", response_model=WishlistOut, summary="View wishlist", description=_NOTE)
def get_wishlist(user: CurrentUser = Depends(require_customer), service: WishlistService = Depends(get_service)):
    return service.view(user)


@router.post("/items", response_model=WishlistItemOut, status_code=status.HTTP_201_CREATED, summary="Save a product",
             description=_NOTE + " The product must be publicly listed (404 otherwise); out-of-stock products can be saved. "
             "Saving the same product again is idempotent: it returns the existing entry with 200.", responses={**E404, **E409, **E422})
def add_item(body: WishlistAdd, response: Response, user: CurrentUser = Depends(require_customer), service: WishlistService = Depends(get_service)):
    item, created = service.add(user, body.product_id)
    response.status_code = status.HTTP_201_CREATED if created else status.HTTP_200_OK
    return item


@router.delete("/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Remove a saved product", description=_NOTE,
               responses={**E404, **E422})
def remove_item(item_id: UUID, user: CurrentUser = Depends(require_customer), service: WishlistService = Depends(get_service)):
    service.remove(user, item_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
