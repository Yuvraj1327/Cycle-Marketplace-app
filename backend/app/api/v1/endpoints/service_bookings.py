from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E409, E422, PROTECTED
from app.core.dependencies import CurrentUser, get_admin_db, get_user_db, require_customer
from app.schemas.booking import (
    BookingCreate,
    BookingDetail,
    BookingImageOut,
    BookingOptions,
    BookingStatus,
    BookingSummary,
    CancelBooking,
    ImageRegister,
    Tracking,
)
from app.schemas.common import Page
from app.schemas.support import TicketCreate, TicketOut
from app.services.booking_service import BookingService
from app.services.support_service import SupportService

router = APIRouter(prefix="/service-bookings", tags=["Service bookings"], responses=PROTECTED)
support = APIRouter(prefix="/support-tickets", tags=["Support"], responses=PROTECTED)
_NOTE = "**Protected - customer role.** Your own bookings only (someone else's booking is a 404)."


def get_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> BookingService:
    return BookingService(db, admin_db)


@router.get("/options", response_model=BookingOptions, summary="Booking form options",
            description=_NOTE + " Pickup/drop-off charges (null until the admin configures them), minimum notice and how far ahead bookings are allowed.")
def booking_options(_user: CurrentUser = Depends(require_customer), service: BookingService = Depends(get_service)):
    return service.options()


@router.post("", response_model=BookingDetail, status_code=status.HTTP_201_CREATED, summary="Book a service",
             description="**Protected - customer role.** The customer comes from your session and the provider from the chosen service. The PRICE is read from the database "
             "(never from the request). `slot_start` must be a slot returned by `GET /services/{id}/availability`; it becomes your PREFERRED time and the provider confirms the "
             "appointment. For doorstep pickup/drop-off send `needs_pickup_dropoff` and your saved `pickup_address_id` (drop-off defaults to it); pickup/drop-off charges come from "
             "platform settings and are recorded as 0 with `logistics_charges_configured: false` when none is configured. After creating the booking, upload photos to "
             "Storage (`service-images/<your_user_id>/<booking_id>/<file>`) and register them with `POST /service-bookings/{id}/images`. No payment is taken.",
             responses={**E404, **E409, **E422})
def create_booking(body: BookingCreate, user: CurrentUser = Depends(require_customer), service: BookingService = Depends(get_service)):
    return service.create(user, body)


@router.get("", response_model=Page[BookingSummary], summary="My bookings", description=_NOTE + " Newest first; filter by `status`.", responses=E422)
def list_bookings(status: BookingStatus | None = None, page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                  user: CurrentUser = Depends(require_customer), service: BookingService = Depends(get_service)):
    return service.list(user, status=status.value if status else None, page=page, limit=limit)


@router.get("/{booking_id}", response_model=BookingDetail, summary="Booking details",
            description=_NOTE + " Includes service, provider, cycle, issue, preferred vs confirmed schedule, pricing (the original estimate is never overwritten; additional charges "
            "are listed separately), pickup/drop-off details and stages, service notes, and photos as short-lived signed URLs.", responses={**E404, **E422})
def get_booking(booking_id: UUID, user: CurrentUser = Depends(require_customer), service: BookingService = Depends(get_service)):
    return service.get(user, booking_id)


@router.get("/{booking_id}/tracking", response_model=Tracking, summary="Booking progress",
            description=_NOTE + " Status timeline from stored history, pickup/drop-off stages and schedule, charges and notes. No live GPS.", responses={**E404, **E422})
def tracking(booking_id: UUID, user: CurrentUser = Depends(require_customer), service: BookingService = Depends(get_service)):
    return service.tracking(user, booking_id)


@router.post("/{booking_id}/cancel", response_model=BookingDetail, summary="Cancel a booking",
             description=_NOTE + " Only while `pending` or `accepted` (before the cycle is collected / work starts). Releases the confirmed slot and cancels pickup/drop-off. Reason required.",
             responses={**E404, **E409, **E422})
def cancel(booking_id: UUID, body: CancelBooking, user: CurrentUser = Depends(require_customer), service: BookingService = Depends(get_service)):
    return service.cancel(user, booking_id, body.reason)


@router.post("/{booking_id}/images", response_model=BookingImageOut, status_code=status.HTTP_201_CREATED, summary="Attach an uploaded cycle photo",
             description=_NOTE + " Files are uploaded straight to Supabase Storage with your own session (private bucket `service-images`, 5 MB, jpeg/png/webp) at "
             "`<your_user_id>/<booking_id>/<file>`; this registers the path after checking it exists. Up to 5 photos, only while the booking is `pending`.",
             responses={**E404, **E409, **E422})
def add_image(booking_id: UUID, body: ImageRegister, user: CurrentUser = Depends(require_customer), service: BookingService = Depends(get_service)):
    return service.add_image(user, booking_id, body)


@router.delete("/{booking_id}/images/{image_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Remove a photo", description=_NOTE + " Only while `pending`.",
               responses={**E404, **E409, **E422})
def remove_image(booking_id: UUID, image_id: UUID, user: CurrentUser = Depends(require_customer), service: BookingService = Depends(get_service)):
    service.remove_image(user, booking_id, image_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# ---------------- complaints / support (no chat)
def support_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> SupportService:
    return SupportService(db, admin_db)


@support.post("", response_model=TicketOut, status_code=status.HTTP_201_CREATED, summary="Raise a complaint / support request",
              description="**Protected - customer role.** Optionally linked to one of YOUR orders or service bookings.", responses=E422)
def create_ticket(body: TicketCreate, user: CurrentUser = Depends(require_customer), service: SupportService = Depends(support_service)):
    return service.create(user, body)


@support.get("", response_model=Page[TicketOut], summary="My tickets", description="**Protected - customer role.**", responses=E422)
def list_tickets(status: str | None = Query(None, pattern="^(open|in_progress|resolved|closed)$"), page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100),
                 user: CurrentUser = Depends(require_customer), service: SupportService = Depends(support_service)):
    return service.list_own(user, status=status, page=page, limit=limit)


@support.get("/{ticket_id}", response_model=TicketOut, summary="One of my tickets", description="**Protected - customer role.**", responses={**E404, **E422})
def get_ticket(ticket_id: UUID, user: CurrentUser = Depends(require_customer), service: SupportService = Depends(support_service)):
    return service.get_own(user, ticket_id)
