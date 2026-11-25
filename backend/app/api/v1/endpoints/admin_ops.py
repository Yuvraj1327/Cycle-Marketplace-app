"""Step 10: coupons, announcements/notification history, reports, fulfilment overview and the audit trail (all admin only)."""
from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, Query, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_user_db, require_admin
from app.schemas.admin_ops import (
    AdminNotificationOut,
    AdminVendorOrderItem,
    AnnouncementCreate,
    AnnouncementOut,
    AnnouncementType,
    Audience,
    AuditOut,
    CouponCreate,
    CouponOut,
    CouponUpdate,
    ReportKind,
    ReportOut,
)
from app.schemas.common import Page
from app.schemas.order import VendorOrderStatus
from app.services.admin_ops_service import (
    AuditAdminService,
    CommunicationAdminService,
    CouponAdminService,
    FulfilmentAdminService,
    ReportAdminService,
)

ADMIN = "**Protected - admin role only** (runs as the admin; changes are written to the audit log)."
coupons = APIRouter(prefix="/admin/coupons", tags=["Admin - Coupons"], responses=PROTECTED)
announcements = APIRouter(prefix="/admin/announcements", tags=["Admin - Notifications"], responses=PROTECTED)
notifications = APIRouter(prefix="/admin/notifications", tags=["Admin - Notifications"], responses=PROTECTED)
reports = APIRouter(prefix="/admin/reports", tags=["Admin - Reports"], responses=PROTECTED)
fulfilment = APIRouter(prefix="/admin/vendor-orders", tags=["Admin - Fulfilment"], responses=PROTECTED)
audit = APIRouter(prefix="/admin/audit-log", tags=["Admin - Audit"], responses=PROTECTED)


def coupon_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> CouponAdminService:
    return CouponAdminService(db, admin_db)


def comms_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> CommunicationAdminService:
    return CommunicationAdminService(db, admin_db)


# ---------------- coupons
@coupons.get("", response_model=Page[CouponOut], summary="Coupons", description=ADMIN + " `q` searches code/description; `is_active` filters the switch. "
             "`state` (active|inactive|scheduled|expired|exhausted) is derived from the dates and usage limit at request time. Only a usage COUNTER exists - "
             "there is no per-redemption table; use the orders' `coupon_code` for individual uses.", responses=E422)
def list_coupons(q: str | None = Query(None, max_length=50), is_active: bool | None = None, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                 _a: CurrentUser = Depends(require_admin), service: CouponAdminService = Depends(coupon_service)):
    return service.list(q=q, is_active=is_active, page=page, limit=limit)


@coupons.post("", response_model=CouponOut, status_code=status.HTTP_201_CREATED, summary="Create a coupon",
              description=ADMIN + " Codes are stored upper-case and are unique case-insensitively. Redeemed at product checkout only.", responses={**E409, **E422})
def create_coupon(body: CouponCreate, admin: CurrentUser = Depends(require_admin), service: CouponAdminService = Depends(coupon_service)):
    return service.create(admin, body)


@coupons.get("/{coupon_id}", response_model=CouponOut, summary="One coupon", description=ADMIN, responses={**E404, **E422})
def get_coupon(coupon_id: UUID, _a: CurrentUser = Depends(require_admin), service: CouponAdminService = Depends(coupon_service)):
    return service.get(coupon_id)


@coupons.put("/{coupon_id}", response_model=CouponOut, summary="Edit / activate / deactivate a coupon",
             description=ADMIN + " Partial update. The code cannot change once the coupon has been used; the usage limit cannot drop below the redemptions already made. "
             "There is no delete: deactivate instead (orders keep the coupon code they used).", responses={**E404, **E409, **E422})
def update_coupon(coupon_id: UUID, body: CouponUpdate, admin: CurrentUser = Depends(require_admin), service: CouponAdminService = Depends(coupon_service)):
    return service.update(admin, coupon_id, body)


# ---------------- announcements & notification history
@announcements.post("", response_model=AnnouncementOut, status_code=status.HTTP_201_CREATED, summary="Send an announcement",
                    description=ADMIN + " Creates one in-app notification per ACTIVE recipient, atomically (all or none) - customers, vendors, or a specific list. "
                    "This is an in-app record only: no push message is sent (push delivery is a later step). 409 when there is nobody to notify.",
                    responses={**E409, **E422})
def send_announcement(body: AnnouncementCreate, admin: CurrentUser = Depends(require_admin), service: CommunicationAdminService = Depends(comms_service)):
    return service.send(admin, body)


@announcements.get("", response_model=Page[AnnouncementOut], summary="Announcement history", description=ADMIN + " With how many in-app notifications exist and how many were read.", responses=E422)
def list_announcements(type: AnnouncementType | None = None, audience: Audience | None = None, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                       _a: CurrentUser = Depends(require_admin), service: CommunicationAdminService = Depends(comms_service)):
    return service.list(type=type.value if type else None, audience=audience.value if audience else None, page=page, limit=limit)


@notifications.get("", response_model=Page[AdminNotificationOut], summary="All in-app notification records",
                   description=ADMIN + " Order, payment, service, pickup, promotion, announcement and system notifications sent to any user, newest first. `q` searches the recipient "
                   "(name/e-mail/phone). Delivery means the in-app row exists; push delivery is not implemented yet.", responses=E422)
def list_notifications(type: str | None = Query(None, pattern="^(order|payment|service_booking|pickup_delivery|promotion|announcement|system)$"), user_id: UUID | None = None,
                       announcement_id: UUID | None = None, q: str | None = Query(None, max_length=60), date_from: date | None = None, date_to: date | None = None,
                       page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100), _a: CurrentUser = Depends(require_admin),
                       service: CommunicationAdminService = Depends(comms_service)):
    return service.list_notifications(type=type, user_id=user_id, announcement_id=announcement_id, q=q, date_from=date_from, date_to=date_to, page=page, limit=limit)


# ---------------- reports
@reports.get("/{kind}", response_model=ReportOut, summary="Report", description=ADMIN + " kind: orders | sales | vendors | customers | services | payments. Period = inclusive "
             "platform-local days (default: last 30 days, max 366). Definitions: orders = orders created in the period; sales = vendor orders DELIVERED in the period "
             "(item value); payments = payments created in the period, except collected/refunded which follow the money; services = bookings created in the period. "
             "Read-only SQL aggregates; nothing is estimated.", responses=E422)
def get_report(kind: ReportKind, date_from: date | None = Query(None, alias="from"), date_to: date | None = Query(None, alias="to"),
               _a: CurrentUser = Depends(require_admin), admin_db: SyncPostgrestClient = Depends(get_admin_db)):
    return ReportAdminService(admin_db).report(kind, date_from, date_to)


# ---------------- fulfilment overview
@fulfilment.get("", response_model=Page[AdminVendorOrderItem], summary="Fulfilment overview: every vendor order",
                description=ADMIN + " Vendor orders released to vendors (confirmed COD, or verified online payment) with customer, delivery city, payment state and fulfilment status. "
                "Filter by status, vendor, created date; `q` searches order number, customer or seller. Monitoring only - there is no courier or GPS tracking.", responses=E422)
def list_vendor_orders(status: VendorOrderStatus | None = None, vendor_id: UUID | None = None, q: str | None = Query(None, max_length=40), date_from: date | None = None,
                       date_to: date | None = None, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                       _a: CurrentUser = Depends(require_admin), db: SyncPostgrestClient = Depends(get_user_db)):
    return FulfilmentAdminService(db).list(status=status.value if status else None, vendor_id=vendor_id, q=q, date_from=date_from, date_to=date_to, page=page, limit=limit)


# ---------------- audit trail
@audit.get("", response_model=Page[AuditOut], summary="Administrative audit trail",
           description=ADMIN + " Who changed what: product moderation, orders, refunds, commission rules, settings, coupons, announcements, vendor decisions. Newest first.", responses=E422)
def list_audit(entity_type: str | None = Query(None, max_length=40, pattern="^[a-z_]+$"), entity_id: UUID | None = None, action: str | None = Query(None, max_length=60, pattern="^[a-z_]+$"),
               actor_id: UUID | None = None, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
               _a: CurrentUser = Depends(require_admin), db: SyncPostgrestClient = Depends(get_user_db)):
    return AuditAdminService(db).list(entity_type=entity_type, entity_id=entity_id, action=action, actor_id=actor_id, page=page, limit=limit)
