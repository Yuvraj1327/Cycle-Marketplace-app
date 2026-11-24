from uuid import UUID

from fastapi import APIRouter, Depends, Query
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_provider, get_user_db, require_customer
from app.integrations.payments.base import PaymentProvider
from app.schemas.common import Page
from app.schemas.order import CancelRequest, OrderDetailOut, OrderStatus, OrderSummaryOut, PaymentStatus, TrackingOut
from app.schemas.payment import PaymentOut
from app.services.order_service import OrderService
from app.services.payment_service import PaymentService

router = APIRouter(prefix="/orders", tags=["Orders"], responses=PROTECTED)
_NOTE = "**Protected - customer role.** Your own orders only (another customer's order is a 404)."


def get_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> OrderService:
    return OrderService(db, admin_db)


@router.get("", response_model=Page[OrderSummaryOut], summary="My orders",
            description=_NOTE + " Newest first; filter by `status` and `payment_status`; paginated.", responses=E422)
def list_orders(status: OrderStatus | None = None, payment_status: PaymentStatus | None = None, page: int = Query(1, ge=1, le=10_000),
                limit: int = Query(20, ge=1, le=100), user: CurrentUser = Depends(require_customer), service: OrderService = Depends(get_service)):
    return service.list(user, status=status.value if status else None, payment_status=payment_status.value if payment_status else None, page=page, limit=limit)


@router.get("/{order_id}", response_model=OrderDetailOut, summary="Order details",
            description=_NOTE + " Includes the delivery-address snapshot, per-seller fulfilment (`vendor_orders`), item snapshots (name, price, quantity as purchased) "
            "and `can_cancel`.", responses={**E404, **E422})
def get_order(order_id: UUID, user: CurrentUser = Depends(require_customer), service: OrderService = Depends(get_service)):
    return service.get(user, order_id)


@router.get("/{order_id}/tracking", response_model=TrackingOut, summary="Order progress",
            description=_NOTE + " Status timeline from the order's history (no live GPS).", responses={**E404, **E422})
def tracking(order_id: UUID, user: CurrentUser = Depends(require_customer), service: OrderService = Depends(get_service)):
    return service.tracking(user, order_id)


@router.post("/{order_id}/cancel", response_model=OrderDetailOut, summary="Cancel an order",
             description=_NOTE + " Allowed while every seller is still `pending`/`accepted` (nothing prepared yet). Reserved stock is returned once; "
             "if the order was already paid a refund is REQUESTED (an admin processes it - nothing is claimed refunded here).",
             responses={**E404, **E409, **E422})
def cancel_order(order_id: UUID, body: CancelRequest, user: CurrentUser = Depends(require_customer), service: OrderService = Depends(get_service)):
    return service.cancel(user, order_id, body.reason)


@router.get("/{order_id}/payment", response_model=list[PaymentOut], summary="Payments of an order",
            description=_NOTE + " One entry per payment attempt, oldest first.", responses={**E404, **E422})
def order_payments(order_id: UUID, user: CurrentUser = Depends(require_customer), db: SyncPostgrestClient = Depends(get_user_db),
                   admin_db: SyncPostgrestClient = Depends(get_admin_db), provider: PaymentProvider = Depends(get_provider)):
    return PaymentService(db, admin_db, provider).for_order(user, order_id)
