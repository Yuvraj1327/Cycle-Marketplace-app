from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_provider, get_user_db, require_admin
from app.integrations.payments.base import PaymentProvider
from app.schemas.admin_config import CommissionRuleCreate, CommissionRuleOut, CommissionRuleUpdate, SettingOut, SettingUpdate
from app.schemas.common import Page
from app.schemas.order import AdminOrderOut, AdminStatusUpdate, OrderStatus, PaymentMethod, PaymentStatus
from app.schemas.payment import AdminPaymentDetail, AdminPaymentOut, RevenueSummary
from app.schemas.refund import RefundAction, RefundCreate, RefundOut, RefundStatus
from app.schemas.settlement import MarkPaid, SettlementOut, SettlementPage
from app.services.admin_config_service import AdminConfigService
from app.services.admin_order_service import AdminOrderService
from app.services.payment_service import PaymentService
from app.services.refund_service import RefundService
from app.services.settlement_service import SettlementService

ADMIN = "**Protected - admin role only** (runs as the admin; actions are written to the audit log)."
orders = APIRouter(prefix="/admin/orders", tags=["Admin - Orders"], responses=PROTECTED)
payments = APIRouter(prefix="/admin/payments", tags=["Admin - Payments"], responses=PROTECTED)
refunds = APIRouter(prefix="/admin/refunds", tags=["Admin - Refunds"], responses=PROTECTED)
settlements = APIRouter(prefix="/admin/settlements", tags=["Admin - Settlements"], responses=PROTECTED)
config = APIRouter(prefix="/admin", tags=["Admin - Settings"], responses=PROTECTED)


def order_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> AdminOrderService:
    return AdminOrderService(db, admin_db)


def payment_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db),
                    provider: PaymentProvider = Depends(get_provider)) -> PaymentService:
    return PaymentService(db, admin_db, provider)


def refund_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db),
                   provider: PaymentProvider = Depends(get_provider)) -> RefundService:
    return RefundService(db, admin_db, provider)


# ---------------- orders
@orders.get("", response_model=Page[AdminOrderOut], summary="All orders", description=ADMIN + " Filter by status, payment status/method, vendor, customer; "
            "`q` searches the order number.", responses=E422)
def list_orders(status: OrderStatus | None = None, payment_status: PaymentStatus | None = None, payment_method: PaymentMethod | None = None,
                vendor_id: UUID | None = None, customer_id: UUID | None = None, q: str | None = Query(None, max_length=40),
                page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                _a: CurrentUser = Depends(require_admin), service: AdminOrderService = Depends(order_service)):
    return service.list(status=status.value if status else None, payment_status=payment_status.value if payment_status else None,
                        payment_method=payment_method.value if payment_method else None, vendor_id=vendor_id, customer_id=customer_id, q=q, page=page, limit=limit)


@orders.post("/expire-unpaid", summary="Cancel overdue unpaid online orders", description=ADMIN + " Returns reserved stock for online orders whose payment window "
             "passed. Call from a scheduler (e.g. Supabase cron) every few minutes; checkout also does a small best-effort sweep.")
def expire_unpaid(admin: CurrentUser = Depends(require_admin), service: AdminOrderService = Depends(order_service)):
    return service.expire_unpaid(admin)


@orders.get("/{order_id}", response_model=AdminOrderOut, summary="Order with customer, items, payments, refunds", description=ADMIN, responses={**E404, **E422})
def get_order(order_id: UUID, _a: CurrentUser = Depends(require_admin), service: AdminOrderService = Depends(order_service)):
    return service.get(order_id)


@orders.patch("/{order_id}/status", response_model=AdminOrderOut, summary="Cancel an order / change one vendor order",
              description=ADMIN + " Without `vendor_order_id`: only `cancelled` (reason required) - stock is returned once and a refund is requested if paid. "
              "With `vendor_order_id`: that vendor order follows the vendor state machine (admins may cancel any active one).", responses={**E404, **E409, **E422})
def set_status(order_id: UUID, body: AdminStatusUpdate, admin: CurrentUser = Depends(require_admin), service: AdminOrderService = Depends(order_service)):
    return service.set_status(admin, order_id, body)


# ---------------- payments
@payments.get("", response_model=Page[AdminPaymentOut], summary="Transactions", description=ADMIN + " Filter by status, method, order, customer, `needs_review` "
              "(amount mismatches, late/duplicate payments).", responses=E422)
def list_payments(status: PaymentStatus | None = None, method: PaymentMethod | None = None, order_id: UUID | None = None, customer_id: UUID | None = None,
                  needs_review: bool | None = None, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                  _a: CurrentUser = Depends(require_admin), service: AdminOrderService = Depends(order_service)):
    return service.list_payments(status=status.value if status else None, method=method.value if method else None, order_id=order_id,
                                 customer_id=customer_id, needs_review=needs_review, page=page, limit=limit)


@payments.get("/summary", response_model=RevenueSummary, summary="Platform revenue summary", description=ADMIN + " Collected, refunded, commission earned, "
              "COD outstanding and settlement totals for a period (default last 30 days).", responses=E422)
def revenue(date_from: datetime | None = Query(None, alias="from"), date_to: datetime | None = Query(None, alias="to"),
            _a: CurrentUser = Depends(require_admin), service: AdminOrderService = Depends(order_service)):
    return service.revenue(date_from, date_to)


@payments.get("/{payment_id}", response_model=AdminPaymentDetail, summary="Payment with provider events and refunds", description=ADMIN, responses={**E404, **E422})
def get_payment(payment_id: UUID, _a: CurrentUser = Depends(require_admin), service: AdminOrderService = Depends(order_service)):
    return service.payment_detail(payment_id)


@payments.post("/{payment_id}/collect-cod", summary="Record COD cash collected",
               description=ADMIN + " The ONLY way a COD payment becomes successful. Allowed once the order is out for delivery or delivered; makes the vendor's "
               "settlement `ready`. Vendors and customers cannot do this.", responses={**E404, **E409, **E422})
def collect_cod(payment_id: UUID, admin: CurrentUser = Depends(require_admin), service: PaymentService = Depends(payment_service)):
    return service.collect_cod(admin, payment_id)


@payments.post("/{payment_id}/reconcile", summary="Ask the provider for the payment's true state",
               description=ADMIN + " Applies the provider's answer through the same verified, idempotent path as a webhook. 503 until a provider is configured.",
               responses={**E404, **E409, **E422})
def reconcile(payment_id: UUID, admin: CurrentUser = Depends(require_admin), service: PaymentService = Depends(payment_service)):
    return service.reconcile(admin, payment_id)


# ---------------- refunds
@refunds.get("", response_model=Page[RefundOut], summary="Refund records", description=ADMIN, responses=E422)
def list_refunds(status: RefundStatus | None = None, order_id: UUID | None = None, payment_id: UUID | None = None, page: int = Query(1, ge=1, le=10_000),
                 limit: int = Query(20, ge=1, le=100), _a: CurrentUser = Depends(require_admin), service: RefundService = Depends(refund_service)):
    return service.list(status=status.value if status else None, order_id=order_id, payment_id=payment_id, page=page, limit=limit)


@refunds.post("", response_model=RefundOut, status_code=status.HTTP_201_CREATED, summary="Create a refund request",
              description=ADMIN + " Creates a `requested` refund against a paid payment. Refused when it would exceed the paid amount (including refunds already "
              "requested/processed). `Idempotency-Key` header required: repeating it returns the same refund. Nothing is refunded until it is approved and processed.",
              responses={**E400, **E404, **E409, **E422})
def create_refund(body: RefundCreate, idempotency_key: str = Header(..., alias="Idempotency-Key", min_length=8, max_length=100),
                  admin: CurrentUser = Depends(require_admin), service: RefundService = Depends(refund_service)):
    return service.create(admin, body, idempotency_key.strip())


@refunds.get("/{refund_id}", response_model=RefundOut, summary="Refund details", description=ADMIN, responses={**E404, **E422})
def get_refund(refund_id: UUID, _a: CurrentUser = Depends(require_admin), service: RefundService = Depends(refund_service)):
    return service.get(refund_id)


@refunds.post("/{refund_id}/actions", response_model=RefundOut, summary="Approve / reject / process / fail a refund",
              description=ADMIN + " `process` asks the payment provider to refund (503 until one is configured) and only marks it processed after the provider "
              "confirms (synchronously or by verified webhook). `manual=true` records a refund finance paid outside the system and needs the external reference.",
              responses={**E404, **E409, **E422, 503: {"description": "No payment provider configured"}})
def refund_action(refund_id: UUID, body: RefundAction, admin: CurrentUser = Depends(require_admin), service: RefundService = Depends(refund_service)):
    return service.act(admin, refund_id, body)


# ---------------- settlements
@settlements.get("", response_model=SettlementPage, summary="Vendor settlement records",
                 description=ADMIN + " Gross, commission, deductions, net per delivered vendor order, with totals by status. Records only - no payout is executed.", responses=E422)
def list_settlements(vendor_id: UUID | None = None, status: str | None = Query(None, pattern="^(pending|ready|paid|cancelled)$"), page: int = Query(1, ge=1, le=10_000),
                     limit: int = Query(20, ge=1, le=100), db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db),
                     _a: CurrentUser = Depends(require_admin)):
    return SettlementService(db, admin_db).list(vendor_id=vendor_id, status=status, page=page, limit=limit)


@settlements.post("/{settlement_id}/mark-paid", response_model=SettlementOut, summary="Record that a vendor was paid (outside this system)",
                  description=ADMIN + " Only for `ready` settlements. Requires the external payout reference. This records a payment made elsewhere; the platform "
                  "does not initiate bank transfers.", responses={**E404, **E409, **E422})
def mark_paid(settlement_id: UUID, body: MarkPaid, admin: CurrentUser = Depends(require_admin), db: SyncPostgrestClient = Depends(get_user_db),
              admin_db: SyncPostgrestClient = Depends(get_admin_db)):
    return SettlementService(db, admin_db).mark_paid(admin, settlement_id, body)


# ---------------- settings & commission rules
def config_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> AdminConfigService:
    return AdminConfigService(db, admin_db)


@config.get("/settings", response_model=list[SettingOut], summary="Checkout / payment settings", description=ADMIN + " Includes what happens while a setting is unset.")
def get_settings(_a: CurrentUser = Depends(require_admin), service: AdminConfigService = Depends(config_service)):
    return service.list_settings()


@config.put("/settings/{key}", response_model=SettingOut, summary="Change a setting",
            description=ADMIN + " Keys: payments.cod_enabled, payments.online_enabled, checkout.multi_vendor_policy (single_vendor_only | allow_multi_vendor), "
            "checkout.delivery_charge, commission.missing_rule_policy (block | zero), checkout.payment_window_minutes, marketplace.require_listing_approval.",
            responses={**E422})
def put_setting(key: str, body: SettingUpdate, admin: CurrentUser = Depends(require_admin), service: AdminConfigService = Depends(config_service)):
    return service.put_setting(admin, key, body.value)


@config.get("/commission-rules", response_model=list[CommissionRuleOut], summary="Commission rules", description=ADMIN)
def list_rules(_a: CurrentUser = Depends(require_admin), service: AdminConfigService = Depends(config_service)):
    return service.list_rules()


@config.post("/commission-rules", response_model=CommissionRuleOut, status_code=status.HTTP_201_CREATED, summary="Create a commission rule",
             description=ADMIN + " Most specific active rule wins: vendor-specific, then category-specific, then global; then `priority`. `percentage` = % of the "
             "item value; `fixed` = flat amount per unit. Orders snapshot the rate they used, so later changes never alter past orders.", responses=E422)
def create_rule(body: CommissionRuleCreate, admin: CurrentUser = Depends(require_admin), service: AdminConfigService = Depends(config_service)):
    return service.create_rule(admin, body)


@config.put("/commission-rules/{rule_id}", response_model=CommissionRuleOut, summary="Edit / deactivate a commission rule", description=ADMIN + " Partial update.",
            responses={**E400, **E404, **E422})
def update_rule(rule_id: UUID, body: CommissionRuleUpdate, admin: CurrentUser = Depends(require_admin), service: AdminConfigService = Depends(config_service)):
    return service.update_rule(admin, rule_id, body)


@config.delete("/commission-rules/{rule_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Delete a commission rule",
               description=ADMIN + " Past orders keep their commission snapshot. Prefer deactivating.", responses={**E404, **E422})
def delete_rule(rule_id: UUID, admin: CurrentUser = Depends(require_admin), service: AdminConfigService = Depends(config_service)):
    service.delete_rule(admin, rule_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
