from uuid import UUID

from fastapi import APIRouter, Depends, Query
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E409, E422, PROTECTED
from app.core.dependencies import ApprovedVendor, get_admin_db, get_user_db, require_approved_vendor
from app.schemas.common import Page
from app.schemas.order import VendorAccept, VendorOrderDetail, VendorOrderListItem, VendorOrderStatus, VendorReject, VendorStatusUpdate
from app.schemas.settlement import SettlementOut
from app.services.vendor_order_service import VendorOrderService

router = APIRouter(prefix="/vendor", tags=["Vendor orders"], responses=PROTECTED)
_NOTE = ("**Protected - approved vendors only.** `{order_id}` is YOUR vendor-order id. Orders appear once they are confirmed (COD at checkout, online after "
         "verified payment). Another vendor's order is a 404. Status names: preparing = processing, out_for_delivery = shipped, delivered = fulfilled.")


def get_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> VendorOrderService:
    return VendorOrderService(db, admin_db)


@router.get("/orders", response_model=Page[VendorOrderListItem], summary="My incoming and past orders",
            description=_NOTE + " Filter by `status` (pending = waiting for you, delivered = completed sales, cancelled/rejected...).", responses=E422)
def list_orders(status: VendorOrderStatus | None = None, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorOrderService = Depends(get_service)):
    return service.list(vendor, status=status.value if status else None, page=page, limit=limit)


@router.get("/orders/{order_id}", response_model=VendorOrderDetail, summary="Order details",
            description=_NOTE + " Includes the delivery name/phone/address needed to fulfil it, items, payment method/status, your commission and net payable.",
            responses={**E404, **E422})
def get_order(order_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorOrderService = Depends(get_service)):
    return service.get(vendor, order_id)


@router.post("/orders/{order_id}/accept", response_model=VendorOrderDetail, summary="Accept an order", description=_NOTE + " Only from `pending`.",
             responses={**E404, **E409, **E422})
def accept(order_id: UUID, body: VendorAccept | None = None, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorOrderService = Depends(get_service)):
    return service.accept(vendor, order_id, body or VendorAccept())


@router.post("/orders/{order_id}/reject", response_model=VendorOrderDetail, summary="Reject an order",
             description=_NOTE + " Only from `pending`; a reason is required. Reserved stock is returned once and, if the customer already paid, a refund is "
             "REQUESTED (never claimed as done).", responses={**E404, **E409, **E422})
def reject(order_id: UUID, body: VendorReject, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorOrderService = Depends(get_service)):
    return service.reject(vendor, order_id, body)


@router.patch("/orders/{order_id}/status", response_model=VendorOrderDetail, summary="Update fulfilment status",
              description=_NOTE + " Allowed steps: accepted -> preparing -> ready_for_dispatch -> out_for_delivery -> delivered (ready_for_dispatch may go "
              "straight to delivered for pickup). `cancelled` (with a reason) is allowed before delivery. Other jumps are refused (409). "
              "Vendors can never change payment status, totals or commission.", responses={**E404, **E409, **E422})
def update_status(order_id: UUID, body: VendorStatusUpdate, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorOrderService = Depends(get_service)):
    return service.update_status(vendor, order_id, body)


@router.get("/settlements", response_model=Page[SettlementOut], summary="My settlement records",
            description=_NOTE + " Per delivered order: gross, commission, deductions, net. `ready` = payment confirmed; `paid` = recorded by the platform "
            "after paying you outside the system. These are records, not payouts.", responses=E422)
def settlements(status: str | None = Query(None, pattern="^(pending|ready|paid|cancelled)$"), page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorOrderService = Depends(get_service)):
    return service.settlements(vendor, status=status, page=page, limit=limit)
