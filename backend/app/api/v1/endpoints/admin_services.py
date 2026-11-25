from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E400, E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_user_db, require_admin
from app.schemas.admin_ops import AdminTimelineEvent, ServiceStatusUpdate
from app.schemas.booking import AdminBookingDetail, AdminBookingListItem, AdminStatusUpdate, BookingStatus, LogisticsUpdate, PickupListItem
from app.schemas.common import Page
from app.schemas.service import AdminServiceCategoryOut, AdminServiceOut, ServiceCategoryCreate, ServiceCategoryUpdate
from app.schemas.support import AdminTicketOut, TicketStatus, TicketType, TicketUpdate
from app.services.admin_booking_service import AdminBookingService
from app.services.service_category_service import ServiceCategoryService
from app.services.support_service import SupportService

ADMIN = "**Protected - admin role only** (runs as the admin; changes are audited)."
categories = APIRouter(prefix="/admin/service-categories", tags=["Admin - Service categories"], responses=PROTECTED)
services = APIRouter(prefix="/admin/services", tags=["Admin - Services"], responses=PROTECTED)
bookings = APIRouter(prefix="/admin/service-bookings", tags=["Admin - Service bookings"], responses=PROTECTED)
pickups = APIRouter(prefix="/admin/pickup-requests", tags=["Admin - Pickup/drop-off"], responses=PROTECTED)
tickets = APIRouter(prefix="/admin/support-tickets", tags=["Admin - Support"], responses=PROTECTED)


def cat_service(db: SyncPostgrestClient = Depends(get_user_db)) -> ServiceCategoryService:
    return ServiceCategoryService(db, admin=True)


def booking_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> AdminBookingService:
    return AdminBookingService(db, admin_db)


# ---------------- categories
@categories.get("", response_model=list[AdminServiceCategoryOut], summary="All service categories (incl. inactive)", description=ADMIN)
def list_categories(_a: CurrentUser = Depends(require_admin), service: ServiceCategoryService = Depends(cat_service)):
    return service.list()


@categories.post("", response_model=AdminServiceCategoryOut, status_code=status.HTTP_201_CREATED, summary="Create a service category",
                 description=ADMIN + " `slug` is generated from the name when omitted. `image_path` is an object in the public `banners` bucket.", responses={**E409, **E422})
def create_category(body: ServiceCategoryCreate, _a: CurrentUser = Depends(require_admin), service: ServiceCategoryService = Depends(cat_service)):
    return service.create(body)


@categories.put("/{category_id}", response_model=AdminServiceCategoryOut, summary="Edit / activate / deactivate", description=ADMIN + " Partial update.",
                responses={**E400, **E404, **E409, **E422})
def update_category(category_id: UUID, body: ServiceCategoryUpdate, _a: CurrentUser = Depends(require_admin), service: ServiceCategoryService = Depends(cat_service)):
    return service.update(str(category_id), body)


@categories.delete("/{category_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Delete an unused category",
                   description=ADMIN + " Refused (409) while any vendor service or booking uses it - deactivate instead.", responses={**E404, **E409, **E422})
def delete_category(category_id: UUID, _a: CurrentUser = Depends(require_admin), service: ServiceCategoryService = Depends(cat_service)):
    service.delete(str(category_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# ---------------- services
@services.get("", response_model=Page[AdminServiceOut], summary="All vendor services", description=ADMIN + " Filter by vendor, category, active flag, availability or name.", responses=E422)
def list_services(vendor_id: UUID | None = None, category_id: UUID | None = None, is_active: bool | None = None, is_available: bool | None = None, q: str | None = Query(None, max_length=60),
                  page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100), _a: CurrentUser = Depends(require_admin),
                  service: AdminBookingService = Depends(booking_service)):
    return service.list_services(vendor_id=vendor_id, category_id=category_id, is_active=is_active, is_available=is_available, q=q, page=page, limit=limit)


@services.get("/{service_id}", response_model=AdminServiceOut, summary="One service with its provider", description=ADMIN, responses={**E404, **E422})
def get_service(service_id: UUID, _a: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.get_service(service_id)


@services.patch("/{service_id}/status", response_model=AdminServiceOut, summary="Deactivate / re-activate a vendor's service",
                description=ADMIN + " A reason is required to deactivate; the vendor is notified. Bookings and the service record are preserved. The vendor can re-activate "
                "their own service - to stop a vendor altogether, suspend the vendor.", responses={**E404, **E409, **E422})
def set_service_status(service_id: UUID, body: ServiceStatusUpdate, admin: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.set_service_status(admin, service_id, body.is_active, body.reason)


# ---------------- bookings
@bookings.get("", response_model=Page[AdminBookingListItem], summary="All service bookings",
              description=ADMIN + " Filter by `status`, `vendor_id`, `customer_id`, preferred-date range; `q` searches the booking number, the customer or the provider's business name.", responses=E422)
def list_bookings(status: BookingStatus | None = None, vendor_id: UUID | None = None, customer_id: UUID | None = None, date_from: date | None = None, date_to: date | None = None,
                  q: str | None = Query(None, max_length=40), page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                  _a: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.list(status=status.value if status else None, vendor_id=vendor_id, customer_id=customer_id, date_from=date_from, date_to=date_to, q=q, page=page, limit=limit)


@bookings.get("/{booking_id}", response_model=AdminBookingDetail, summary="Booking with customer, provider, cycle, charges, pickup", description=ADMIN, responses={**E404, **E422})
def get_booking(booking_id: UUID, admin: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.get(booking_id, admin.access_token)


@bookings.get("/{booking_id}/timeline", response_model=list[AdminTimelineEvent], summary="Booking / repair status history",
              description=ADMIN + " Every recorded status change, oldest first, with who made it.", responses={**E404, **E422})
def booking_timeline(booking_id: UUID, _a: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.timeline(booking_id)


@bookings.patch("/{booking_id}/status", response_model=AdminBookingDetail, summary="Move / reject / cancel a booking",
                description=ADMIN + " Follows the same state machine as providers; admins may additionally cancel a booking that is already being worked on. A reason is required to "
                "reject or cancel. Acceptance stays the provider's decision.", responses={**E404, **E409, **E422})
def set_status(booking_id: UUID, body: AdminStatusUpdate, admin: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.set_status(admin, booking_id, body)


# ---------------- pickup / drop-off
@pickups.get("", response_model=Page[PickupListItem], summary="All pickup and drop-off requests", description=ADMIN + " With booking, provider, customer and both addresses.", responses=E422)
def list_pickups(q: str | None = Query(None, max_length=40), pickup_status: str | None = Query(None, pattern="^(pending|scheduled|completed|failed|cancelled)$"),
                 delivery_status: str | None = Query(None, pattern="^(pending|scheduled|completed|failed|cancelled)$"), page: int = Query(1, ge=1, le=10_000),
                 limit: int = Query(20, ge=1, le=100), _a: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.list_pickups(pickup_status=pickup_status, delivery_status=delivery_status, q=q, page=page, limit=limit)


@pickups.get("/{request_id}", response_model=PickupListItem, summary="One pickup/drop-off request", description=ADMIN, responses={**E404, **E422})
def get_pickup(request_id: UUID, _a: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.get_pickup(request_id)


@pickups.patch("/{request_id}/status", response_model=PickupListItem, summary="Coordinate a pickup / return delivery",
               description=ADMIN + " Schedule/reschedule, mark `failed` or `cancelled`, add notes. Completion is recorded by the booking status (picked_up / completed).",
               responses={**E404, **E409, **E422})
def update_pickup(request_id: UUID, body: LogisticsUpdate, admin: CurrentUser = Depends(require_admin), service: AdminBookingService = Depends(booking_service)):
    return service.update_pickup(admin, request_id, body)


# ---------------- complaints & disputes
def support_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> SupportService:
    return SupportService(db, admin_db)


@tickets.get("", response_model=Page[AdminTicketOut], summary="Complaints, support requests and disputes",
             description=ADMIN + " Filter by status/type or by the linked booking/order.", responses=E422)
def list_tickets(status: TicketStatus | None = None, type: TicketType | None = None, booking_id: UUID | None = None, order_id: UUID | None = None,
                 page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100), _a: CurrentUser = Depends(require_admin),
                 service: SupportService = Depends(support_service)):
    return service.admin_list(status=status.value if status else None, ticket_type=type.value if type else None, booking_id=booking_id, order_id=order_id, page=page, limit=limit)


@tickets.get("/{ticket_id}", response_model=AdminTicketOut, summary="One ticket", description=ADMIN, responses={**E404, **E422})
def get_ticket(ticket_id: UUID, _a: CurrentUser = Depends(require_admin), service: SupportService = Depends(support_service)):
    return service.admin_get(ticket_id)


@tickets.patch("/{ticket_id}", response_model=AdminTicketOut, summary="Triage a ticket", description=ADMIN + " Change status, assign, add notes/resolution.",
               responses={**E400, **E404, **E422})
def update_ticket(ticket_id: UUID, body: TicketUpdate, admin: CurrentUser = Depends(require_admin), service: SupportService = Depends(support_service)):
    return service.admin_update(admin, ticket_id, body)
