from uuid import UUID

from fastapi import APIRouter, Depends, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_user_db, require_customer
from app.schemas.cart import CartItemAdd, CartItemUpdate, CartOut
from app.services.cart_service import CartService

router = APIRouter(prefix="/cart", tags=["Cart"], responses=PROTECTED)
_NOTE = ("**Protected - customer role.** Your own cart only. Prices are current prices; stock is checked but never reserved or "
         "reduced here. No delivery/service charges or discounts are included (checkout is a later step).")


def get_service(db: SyncPostgrestClient = Depends(get_user_db)) -> CartService:
    return CartService(db)


@router.get("", response_model=CartOut, summary="View cart", description=_NOTE + " The cart is created on first use. Each item has a "
            "`status` (ok, not_listed, unavailable, out_of_stock, insufficient_stock) and a `price_changed` flag.")
def get_cart(user: CurrentUser = Depends(require_customer), service: CartService = Depends(get_service)):
    return service.view(user)


@router.post("/items", response_model=CartOut, status_code=status.HTTP_201_CREATED, summary="Add a product",
             description=_NOTE + " Adding a product already in the cart increases its quantity (200). 404 for products that are not publicly listed; "
             "409 `out_of_stock` / `insufficient_stock` / `product_unavailable` / `cart_full`.", responses={**E404, **E409, **E422})
def add_item(body: CartItemAdd, response: Response, user: CurrentUser = Depends(require_customer), service: CartService = Depends(get_service)):
    cart, created = service.add(user, body)
    response.status_code = status.HTTP_201_CREATED if created else status.HTTP_200_OK
    return cart


@router.put("/items/{item_id}", response_model=CartOut, summary="Set an item's quantity",
            description=_NOTE + " Quantity 1-100 (use DELETE to remove). Saving also acknowledges a changed price.", responses={**E404, **E409, **E422})
def update_item(item_id: UUID, body: CartItemUpdate, user: CurrentUser = Depends(require_customer), service: CartService = Depends(get_service)):
    return service.update(user, item_id, body)


@router.delete("/clear", response_model=CartOut, summary="Empty the cart", description=_NOTE)
def clear_cart(user: CurrentUser = Depends(require_customer), service: CartService = Depends(get_service)):
    return service.clear(user)


@router.delete("/items/{item_id}", response_model=CartOut, summary="Remove an item", description=_NOTE + " Returns the updated cart.",
               responses={**E404, **E422})
def remove_item(item_id: UUID, user: CurrentUser = Depends(require_customer), service: CartService = Depends(get_service)):
    return service.remove(user, item_id)
