from fastapi import APIRouter, Depends, Header, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_provider, get_user_db, require_customer
from app.integrations.payments.base import PaymentProvider
from app.schemas.checkout import CheckoutOut, CheckoutRequest
from app.services.checkout_service import CheckoutService

router = APIRouter(prefix="/checkout", tags=["Checkout"], responses=PROTECTED)


def get_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db),
                provider: PaymentProvider = Depends(get_provider)) -> CheckoutService:
    return CheckoutService(db, admin_db, provider)


@router.post(
    "", response_model=CheckoutOut, status_code=status.HTTP_201_CREATED, summary="Check out the cart",
    description="**Protected - customer role.** Send only choices (address, payment method, optional coupon / seller). Prices, discount, delivery "
    "charge, commission and totals are computed on the server from database values; anything amount-like you send is ignored "
    "(`expected_total` is only a consistency check). Stock is reserved atomically; the purchased lines leave the cart.\n\n"
    "**`Idempotency-Key` header is required** (8-100 chars, new value per checkout attempt). Repeating a request with the same key and "
    "body returns the same order (200, `replay: true`) and never creates a second order or reserves stock twice.\n\n"
    "Online: the response carries `client_payload` for the provider's checkout widget; the order stays `pending` until a verified "
    "provider webhook confirms payment. COD: only when an admin enabled it; the order is `confirmed` and the cash is outstanding. "
    "A cart with several sellers is refused (409 `multi_vendor_checkout_not_allowed`) unless the platform allows it or you send `vendor_id`.",
    responses={**E400, **E404, **E409, **E422, 503: {"description": "Payment provider / commission configuration unavailable"}},
)
def checkout(body: CheckoutRequest, response: Response, idempotency_key: str = Header(..., alias="Idempotency-Key", min_length=8, max_length=100),
             user: CurrentUser = Depends(require_customer), service: CheckoutService = Depends(get_service)):
    result = service.checkout(user, body, idempotency_key.strip())
    response.status_code = status.HTTP_200_OK if result["replay"] else status.HTTP_201_CREATED
    return result
