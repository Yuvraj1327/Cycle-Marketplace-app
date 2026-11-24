from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, Query, status
from postgrest import SyncPostgrestClient

from app.api.v1.responses import E404, E409, E422, PROTECTED
from app.core.dependencies import ApprovedVendor, get_admin_db, get_user_db, require_approved_vendor
from app.schemas.booking import (
    AcceptBooking,
    BookingStatus,
    ChargeCreate,
    LogisticsUpdate,
    NoteCreate,
    PickupListItem,
    RejectBooking,
    ScheduleChange,
    StatusUpdate,
    VendorBookingDetail,
    VendorBookingListItem,
)
from app.schemas.common import Page
from app.services.vendor_booking_service import VendorBookingService

router = APIRouter(prefix="/vendor", tags=["Vendor service bookings"], responses=PROTECTED)
_NOTE = "**Protected - approved vendors only.** Your own bookings only (another vendor's booking is a 404)."


def get_service(db: SyncPostgrestClient = Depends(get_user_db), admin_db: SyncPostgrestClient = Depends(get_admin_db)) -> VendorBookingService:
    return VendorBookingService(db, admin_db)


@router.get("/service-bookings", response_model=Page[VendorBookingListItem], summary="Incoming and past service bookings",
            description=_NOTE + " Filter by `status` (pending = waiting for you), preferred date range, or booking number (`q`).", responses=E422)
def list_bookings(status: BookingStatus | None = None, date_from: date | None = None, date_to: date | None = None, q: str | None = Query(None, max_length=30),
                  page: int = Query(1, ge=1, le=10_000), limit: int = Query(20, ge=1, le=100), vendor: ApprovedVendor = Depends(require_approved_vendor),
                  service: VendorBookingService = Depends(get_service)):
    return service.list(vendor, status=status.value if status else None, date_from=date_from, date_to=date_to, q=q, page=page, limit=limit)


@router.get("/service-bookings/{booking_id}", response_model=VendorBookingDetail, summary="Booking details",
            description=_NOTE + " Customer name/phone (no e-mail), cycle details, the complaint, photos (signed URLs), preferred vs confirmed schedule, pricing with additional "
            "charges, notes and pickup/drop-off.", responses={**E404, **E422})
def get_booking(booking_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.get(vendor, booking_id)


@router.post("/service-bookings/{booking_id}/accept", response_model=VendorBookingDetail, summary="Accept a booking",
             description=_NOTE + " Only from `pending`. Confirms the customer's preferred slot, or send `confirmed_date` + `slot_start` to confirm a different valid slot. "
             "Capacity is enforced atomically: 409 `slot_full` when the service's accepted bookings in that slot already reach `max_bookings_per_slot`.",
             responses={**E404, **E409, **E422})
def accept(booking_id: UUID, body: AcceptBooking | None = None, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.accept(vendor, booking_id, body or AcceptBooking())


@router.post("/service-bookings/{booking_id}/reject", response_model=VendorBookingDetail, summary="Reject a booking",
             description=_NOTE + " Only from `pending`; the reason is stored and shown to the customer.", responses={**E404, **E409, **E422})
def reject(booking_id: UUID, body: RejectBooking, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.reject(vendor, booking_id, body)


@router.patch("/service-bookings/{booking_id}/status", response_model=VendorBookingDetail, summary="Repair progress",
              description=_NOTE + " accepted -> picked_up (only for doorstep pickup; records PICKUP COMPLETION) -> in_service -> ready_for_delivery -> completed (records DELIVERY "
              "COMPLETION when drop-off was requested). A booking WITHOUT pickup goes accepted -> in_service directly (the customer brings the cycle). `cancelled` needs a reason "
              "and is allowed only before pickup. Anything else is 409 `invalid_transition`.", responses={**E404, **E409, **E422})
def update_status(booking_id: UUID, body: StatusUpdate, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.update_status(vendor, booking_id, body)


@router.put("/service-bookings/{booking_id}/schedule", response_model=VendorBookingDetail, summary="Change the confirmed appointment",
            description=_NOTE + " Only while `accepted`. The preferred slot the customer chose is kept unchanged; capacity rules apply.", responses={**E404, **E409, **E422})
def reschedule(booking_id: UUID, body: ScheduleChange, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.reschedule(vendor, booking_id, body)


@router.post("/service-bookings/{booking_id}/charges", response_model=VendorBookingDetail, status_code=status.HTTP_201_CREATED, summary="Record an additional repair charge",
             description=_NOTE + " Appended to the charge history with the reason; the ORIGINAL ESTIMATE IS NEVER CHANGED (`current_price` = estimate + charges). A negative amount records "
             "a correction/discount. The customer is notified. Nothing is charged or collected here; whether customers must approve extra charges is a pending client decision.",
             responses={**E404, **E409, **E422})
def add_charge(booking_id: UUID, body: ChargeCreate, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.add_charge(vendor, booking_id, body)


@router.post("/service-bookings/{booking_id}/notes", response_model=VendorBookingDetail, status_code=status.HTTP_201_CREATED, summary="Add a service note",
             description=_NOTE + " Append-only; visible to the customer in their booking.", responses={**E404, **E422})
def add_note(booking_id: UUID, body: NoteCreate, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.add_note(vendor, booking_id, body)


# ---------------- pickup / drop-off coordination
@router.get("/pickup-requests", response_model=Page[PickupListItem], summary="Pickup and drop-off requests",
            description=_NOTE + " Customer name/phone and addresses for collection and return. Stages: requested, scheduled, picked_up / delivered, failed, cancelled.", responses=E422)
def list_pickups(pickup_status: str | None = Query(None, pattern="^(pending|scheduled|completed|failed|cancelled)$"),
                 delivery_status: str | None = Query(None, pattern="^(pending|scheduled|completed|failed|cancelled)$"), page: int = Query(1, ge=1, le=10_000),
                 limit: int = Query(20, ge=1, le=100), vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.list_pickups(vendor, pickup_status=pickup_status, delivery_status=delivery_status, page=page, limit=limit)


@router.get("/pickup-requests/{request_id}", response_model=PickupListItem, summary="One pickup/drop-off request", description=_NOTE, responses={**E404, **E422})
def get_pickup(request_id: UUID, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.get_pickup(vendor, request_id)


@router.patch("/pickup-requests/{request_id}", response_model=PickupListItem, summary="Coordinate pickup / return delivery",
              description=_NOTE + " Schedule or reschedule (`scheduled_pickup_at`, `scheduled_delivery_at`), mark an attempt `failed`, or `cancelled`, and add coordination `notes`. "
              "COMPLETION is recorded by the booking status: `picked_up` completes the pickup, `completed` completes the delivery (single source of truth, no contradictions).",
              responses={**E404, **E409, **E422})
def update_pickup(request_id: UUID, body: LogisticsUpdate, vendor: ApprovedVendor = Depends(require_approved_vendor), service: VendorBookingService = Depends(get_service)):
    return service.update_pickup(vendor, request_id, body)
