from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_user_db, require_admin
from app.schemas.admin_users import (
    AccountStatus,
    AccountStatusChange,
    AdminCustomerDetail,
    AdminCustomerListItem,
    AdminDashboard,
    AdminVendorDetail,
    AdminVendorListItem,
    VendorApprove,
    VendorReject,
    VendorSuspend,
)
from app.schemas.common import Page
from app.schemas.vendor import BusinessType
from app.services.admin_user_service import AdminUserService
from typing import Literal

ADMIN = "**Protected - admin role only** (runs as the admin; every change is written to the audit log; nothing is ever deleted)."
dashboard = APIRouter(prefix="/admin/dashboard", tags=["Admin - Dashboard"], responses=PROTECTED)
customers = APIRouter(prefix="/admin/customers", tags=["Admin - Customers"], responses=PROTECTED)
vendors = APIRouter(prefix="/admin/vendors", tags=["Admin - Vendors"], responses=PROTECTED)

SortBy = Literal["newest", "oldest", "name"]


def get_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> AdminUserService:
    return AdminUserService(db, admin_db)


# ---------------- dashboard
@dashboard.get("", response_model=AdminDashboard, summary="Platform summary",
               description=ADMIN + " Counts by status, order values, and per-day series for `from`..`to` (default: last 30 days, India time; max 366 days). "
               "All figures are computed in the database. Payment collection figures: `GET /admin/payments/summary`.", responses=E422)
def get_dashboard(date_from: date | None = Query(None, alias="from"), date_to: date | None = Query(None, alias="to"),
                  _a: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.dashboard(date_from, date_to)


# ---------------- customers
@customers.get("", response_model=Page[AdminCustomerListItem], summary="List customers",
               description=ADMIN + " `q` searches name, e-mail and phone. Includes order and booking counts per customer.", responses=E422)
def list_customers(q: str | None = Query(None, max_length=100), status: AccountStatus | None = None, sort: SortBy = "newest",
                   page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                   _a: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.list_customers(q=q, status=status.value if status else None, sort=sort, page=page, limit=limit)


@customers.get("/{customer_id}", response_model=AdminCustomerDetail, summary="Customer details",
               description=ADMIN + " Profile, saved addresses and the administrative actions taken on the account. Order and booking history: "
               "`GET /admin/orders?customer_id=` and `GET /admin/service-bookings?customer_id=`.", responses={**E404, **E422})
def get_customer(customer_id: UUID, _a: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.get_customer(customer_id)


@customers.patch("/{customer_id}/status", response_model=AdminCustomerDetail, summary="Activate / deactivate / restrict a customer",
                 description=ADMIN + " A reason (3+ characters) is required unless activating. Orders and bookings are kept. Inactive/restricted accounts are "
                 "refused by the API (`account_inactive` / `account_restricted`). Admins cannot reach passwords.", responses={**E404, **E409, **E422})
def set_customer_status(customer_id: UUID, body: AccountStatusChange, admin: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.set_customer_status(admin, customer_id, body.status.value, body.reason)


# ---------------- vendors
@vendors.get("", response_model=Page[AdminVendorListItem], summary="List vendors",
             description=ADMIN + " `q` searches business name, city, contact details and the owner's name/e-mail/phone. `verification_status` = pending | approved | "
             "rejected | suspended; `account_status` = the owner's account (active | inactive | restricted).", responses=E422)
def list_vendors(q: str | None = Query(None, max_length=100), business_type: BusinessType | None = None,
                 verification_status: Literal["pending", "approved", "rejected", "suspended"] | None = None, account_status: AccountStatus | None = None,
                 sort: SortBy = "newest", page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                 _a: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.list_vendors(q=q, business_type=business_type.value if business_type else None, verification_status=verification_status,
                                account_status=account_status.value if account_status else None, sort=sort, page=page, limit=limit)


@vendors.get("/{vendor_id}", response_model=AdminVendorDetail, summary="Vendor application / business details",
             description=ADMIN + " Everything the vendor submitted, review fields and the audit trail. Products, orders and bookings of the vendor: the existing "
             "`GET /admin/products|orders|service-bookings?vendor_id=`.", responses={**E404, **E422})
def get_vendor(vendor_id: UUID, _a: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.get_vendor(vendor_id)


@vendors.post("/{vendor_id}/approve", response_model=AdminVendorDetail, summary="Approve an application",
              description=ADMIN + " From `pending` (or a previously `rejected` application). Repeating it returns 409 `already_approved`. The vendor is notified.",
              responses={**E404, **E409, **E422})
def approve(vendor_id: UUID, body: VendorApprove | None = None, admin: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.decide(admin, vendor_id, "approve", note=(body.note if body else None))


@vendors.post("/{vendor_id}/reject", response_model=AdminVendorDetail, summary="Reject an application",
              description=ADMIN + " Only from `pending`; the reason is required and shown to the vendor.", responses={**E404, **E409, **E422})
def reject(vendor_id: UUID, body: VendorReject, admin: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.decide(admin, vendor_id, "reject", reason=body.reason)


@vendors.post("/{vendor_id}/suspend", response_model=AdminVendorDetail, summary="Suspend an approved vendor",
              description=ADMIN + " Only from `approved`. Suspended vendors are refused by every business endpoint (403 `vendor_suspended`). History is kept.",
              responses={**E404, **E409, **E422})
def suspend(vendor_id: UUID, body: VendorSuspend, admin: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.decide(admin, vendor_id, "suspend", reason=body.reason)


@vendors.post("/{vendor_id}/reinstate", response_model=AdminVendorDetail, summary="Reinstate a suspended vendor",
              description=ADMIN + " Only from `suspended`.", responses={**E404, **E409, **E422})
def reinstate(vendor_id: UUID, body: VendorApprove | None = None, admin: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.decide(admin, vendor_id, "reinstate", note=(body.note if body else None))


@vendors.patch("/{vendor_id}/account-status", response_model=AdminVendorDetail, summary="Activate / deactivate / restrict the vendor's login account",
               description=ADMIN + " Separate from verification. A reason is required unless activating. Inactive/restricted accounts are refused by the API.",
               responses={**E404, **E409, **E422})
def set_vendor_account_status(vendor_id: UUID, body: AccountStatusChange, admin: CurrentUser = Depends(require_admin), service: AdminUserService = Depends(get_service)):
    return service.set_vendor_account_status(admin, vendor_id, body.status.value, body.reason)
