from uuid import UUID

from fastapi import APIRouter, Depends, Request
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_provider, get_user_db, require_customer
from app.integrations.payments.base import PaymentProvider
from app.schemas.payment import PaymentCreate, PaymentOut, PaymentWithPayload, WebhookAck
from app.services.payment_service import PaymentService

router = APIRouter(prefix="/payments", tags=["Payments"])


def get_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db),
                provider: PaymentProvider = Depends(get_provider)) -> PaymentService:
    return PaymentService(db, admin_db, provider)


@router.post("/create", response_model=PaymentWithPayload, summary="(Re)start online payment for an order",
             description="**Protected - customer role.** For your own unpaid online order: starts a new payment attempt after a failure, or returns "
             "the open attempt (idempotent). Fails with 503 `payment_provider_not_configured` until a provider is configured, 409 once the payment "
             "window has expired. `client_payload` contains only public values for the provider's checkout widget.",
             responses={**PROTECTED, **E404, **E409, **E422})
def create_payment(body: PaymentCreate, user: CurrentUser = Depends(require_customer), service: PaymentService = Depends(get_service)):
    return service.create_for_order(user, body.order_id)


@router.post("/webhook", response_model=WebhookAck, summary="Payment provider webhook",
             description="**Public endpoint, authenticated by the provider's signature** over the raw request body (verified before anything is read). "
             "Idempotent: every event id is processed once, so provider retries are safe. Only verified events change payment/order state; amount or "
             "currency mismatches are flagged for review instead of marking the order paid. 400 `invalid_signature` on a bad signature; "
             "503 until a provider is configured.", responses={**E400})
async def payment_webhook(request: Request, admin_db: SyncPostgrestClient = Depends(get_admin_db), provider: PaymentProvider = Depends(get_provider)):
    # no user context exists here: the provider's signature is the authentication, and state changes use the service client
    body = await request.body()
    return PaymentService(admin_db, admin_db, provider).handle_webhook(request.headers, body)


@router.get("/{payment_id}", response_model=PaymentOut, summary="Payment status",
            description="**Protected - customer role.** Your own payment only. Poll this after the provider's widget closes; the status only changes "
            "on a verified webhook (or an admin recording COD cash).", responses={**PROTECTED, **E404, **E422})
def get_payment(payment_id: UUID, user: CurrentUser = Depends(require_customer), service: PaymentService = Depends(get_service)):
    return service.get(user, payment_id)
