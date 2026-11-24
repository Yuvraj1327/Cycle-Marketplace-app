"""Vendor-side booking management and pickup/drop-off coordination. The vendor id is the approved vendor's own; every booking and pickup
request is re-checked to belong to that vendor, and the SQL functions check again."""
from __future__ import annotations

from uuid import UUID

from app.core.dependencies import ApprovedVendor
from app.core.exceptions import NotFoundError, unprocessable
from app.repositories.booking_repository import BookingRepository, ServiceGateway
from app.repositories.commerce_config_repository import SettingsStore
from app.repositories.service_repository import VendorServiceRepository
from app.schemas.booking import AcceptBooking, ChargeCreate, LogisticsUpdate, NoteCreate, RejectBooking, ScheduleChange, StatusUpdate
from app.services import _catalog
from app.services import _service_views as sv
from app.services._booking_builder import BookingBuilder
from app.services.service_catalog_service import compute_availability, local_now
from app.services.service_settings import KEYS, load_service_settings

PATCHABLE = {"picked_up", "in_service", "ready_for_delivery", "completed", "cancelled"}


class VendorBookingService:
    def __init__(self, db, admin_db):
        self.db = db
        self.bookings = BookingRepository(db)
        self.services = VendorServiceRepository(db)
        self.gateway = ServiceGateway(admin_db)
        self.store = SettingsStore(admin_db)

    def _cfg(self):
        return load_service_settings(self.store.get_many(KEYS))

    # ---------------- reads
    def list(self, vendor: ApprovedVendor, *, status, date_from, date_to, q, page: int, limit: int) -> dict:
        from app.core.search import sanitize_term
        term = sanitize_term(q or "", 30) or None
        rows, total = self.bookings.search(vendor_id=vendor.vendor["id"], status=status, date_from=date_from.isoformat() if date_from else None,
                                           date_to=date_to.isoformat() if date_to else None, number_like=term, page=page, limit=limit)
        return _catalog.page(list_items(self.bookings, rows), total, page, limit)

    def get(self, vendor: ApprovedVendor, booking_id: UUID) -> dict:
        b = self._own(vendor, booking_id)
        out = BookingBuilder(self.db, self._cfg()).detail(b, vendor.user.access_token, can_cancel=False)
        return {**out, "customer": customer_brief(self.bookings, b["customer_id"])}

    def timeline(self, vendor: ApprovedVendor, booking_id: UUID) -> list[dict]:
        b = self._own(vendor, booking_id)
        return [{"at": h["created_at"], "from_status": h.get("from_status"), "to_status": h["to_status"], "note": h.get("note"),
                 "by_role": "customer" if h.get("changed_by") == b["customer_id"] else ("vendor" if h.get("changed_by") == vendor.user.id else None)}
                for h in self.bookings.history(b["id"])]

    # ---------------- decisions
    def accept(self, vendor: ApprovedVendor, booking_id: UUID, body: AcceptBooking) -> dict:
        b = self._own(vendor, booking_id)
        date, start, end = None, None, None
        if body.confirmed_date:
            start, end = self._validated_slot(b, body.confirmed_date, body.slot_start)
            date = body.confirmed_date.isoformat()
        self.gateway.accept(b["id"], vendor.vendor["id"], vendor.user.id, date, start, end, body.note)
        return self.get(vendor, booking_id)

    def reject(self, vendor: ApprovedVendor, booking_id: UUID, body: RejectBooking) -> dict:
        b = self._own(vendor, booking_id)
        self.gateway.transition(b["id"], vendor.vendor["id"], "rejected", vendor.user.id, "vendor", body.reason)
        return self.get(vendor, booking_id)

    def update_status(self, vendor: ApprovedVendor, booking_id: UUID, body: StatusUpdate) -> dict:
        target = body.status.value
        if target not in PATCHABLE:
            raise unprocessable("use_dedicated_endpoint", "Use POST .../accept or POST .../reject for those changes.")
        if target == "cancelled" and len((body.note or "").strip()) < 3:
            raise unprocessable("reason_required", "Give a reason (note) when cancelling a booking.")
        b = self._own(vendor, booking_id)
        self.gateway.transition(b["id"], vendor.vendor["id"], target, vendor.user.id, "vendor", body.note)
        return self.get(vendor, booking_id)

    def reschedule(self, vendor: ApprovedVendor, booking_id: UUID, body: ScheduleChange) -> dict:
        b = self._own(vendor, booking_id)
        start, end = self._validated_slot(b, body.confirmed_date, body.slot_start)
        self.gateway.reschedule(b["id"], vendor.vendor["id"], vendor.user.id, "vendor", body.confirmed_date.isoformat(), start, end, body.note)
        return self.get(vendor, booking_id)

    def add_charge(self, vendor: ApprovedVendor, booking_id: UUID, body: ChargeCreate) -> dict:
        b = self._own(vendor, booking_id)
        self.gateway.add_charge(b["id"], vendor.vendor["id"], vendor.user.id, "vendor", body.amount, body.reason)
        return self.get(vendor, booking_id)

    def add_note(self, vendor: ApprovedVendor, booking_id: UUID, body: NoteCreate) -> dict:
        b = self._own(vendor, booking_id)
        self.gateway.add_note(b["id"], vendor.vendor["id"], vendor.user.id, "vendor", body.note)
        return self.get(vendor, booking_id)

    # ---------------- pickup / drop-off coordination
    def list_pickups(self, vendor: ApprovedVendor, *, pickup_status, delivery_status, page: int, limit: int) -> dict:
        rows, total = self.bookings.list_pickups(pickup_status=pickup_status, delivery_status=delivery_status, page=page, limit=limit)    # RLS: own bookings only
        items = [i for i in pickup_items(self.bookings, rows) if i["_vendor_id"] == vendor.vendor["id"]]
        return _catalog.page([{k: v for k, v in i.items() if k != "_vendor_id"} for i in items], total, page, limit)

    def get_pickup(self, vendor: ApprovedVendor, request_id: UUID) -> dict:
        return self._pickup_view(self._own_pickup(vendor, request_id))

    def update_pickup(self, vendor: ApprovedVendor, request_id: UUID, body: LogisticsUpdate) -> dict:
        r = self._own_pickup(vendor, request_id)
        self.gateway.set_logistics(r["id"], vendor.vendor["id"], vendor.user.id, "vendor", logistics_changes(body))
        return self._pickup_view(self._own_pickup(vendor, request_id))

    # ---------------- internals
    def _own(self, vendor: ApprovedVendor, booking_id: UUID) -> dict:
        b = self.bookings.find(str(booking_id), vendor_id=vendor.vendor["id"])
        if b is None:
            raise NotFoundError("Booking not found.")
        return b

    def _own_pickup(self, vendor: ApprovedVendor, request_id: UUID) -> dict:
        r = self.bookings.find_pickup(str(request_id))
        b = self.bookings.find(r["booking_id"], vendor_id=vendor.vendor["id"]) if r else None
        if r is None or b is None:
            raise NotFoundError("Pickup request not found.")
        return r

    def _pickup_view(self, r: dict) -> dict:
        item = pickup_items(self.bookings, [r])[0]
        item.pop("_vendor_id", None)
        return item

    def _validated_slot(self, b: dict, day, slot_start: str) -> tuple[str, str]:
        service = self.services.find(b["vendor_service_id"]) if b.get("vendor_service_id") else None
        vendor = next(iter(self.services.vendors_public([b["vendor_id"]])), None)
        if service is None or vendor is None:
            raise unprocessable("service_unavailable", "The service for this booking is no longer available, so a slot cannot be validated.")
        avail = compute_availability({**service, "is_active": True, "is_available": True}, vendor, day, {}, self._cfg(), now_local=local_now())
        slot = next((s for s in avail["slots"] if s["start"] == slot_start), None)
        if slot is None:
            raise unprocessable("invalid_slot", "That is not a bookable slot for this service on that date.", details=[{"slots": [s["start"] for s in avail["slots"]], "reason": avail["reason"]}])
        return slot["start"], slot["end"]


def customer_brief(repo: BookingRepository, customer_id: str) -> dict | None:
    row = next(iter(repo.profiles([customer_id])), None)
    return {"full_name": row.get("full_name"), "phone": row.get("phone")} if row else None


def logistics_changes(body: LogisticsUpdate) -> dict:
    out = body.model_dump(mode="json", exclude_unset=True)
    return {k: (v.value if hasattr(v, "value") else v) for k, v in out.items()}


def list_items(repo: BookingRepository, rows: list[dict], *, admin: bool = False) -> list[dict]:
    people = {p["id"]: p for p in repo.profiles(sorted({r["customer_id"] for r in rows}))}
    pickups = {p["booking_id"]: p for p in repo.pickups_for([r["id"] for r in rows])}
    out = []
    for r in rows:
        p, c = pickups.get(r["id"]), people.get(r["customer_id"])
        item = {**sv.summary(r), "customer": {"full_name": c.get("full_name"), "phone": c.get("phone")} if c else None, "issue_description": r["issue_description"],
                "pickup_stage": sv.PICKUP_STAGE[p["pickup_status"]] if p else None, "delivery_stage": sv.DELIVERY_STAGE[p["delivery_status"]] if p else None}
        if admin:
            item.update(customer_id=r["customer_id"], vendor_id=r["vendor_id"])
        out.append(item)
    return out


def pickup_items(repo: BookingRepository, rows: list[dict]) -> list[dict]:
    bookings = {b["id"]: b for b in repo.bookings_by_ids(sorted({r["booking_id"] for r in rows}))}
    people = {p["id"]: p for p in repo.profiles(sorted({b["customer_id"] for b in bookings.values()}))}
    out = []
    for r in rows:
        b = bookings.get(r["booking_id"])
        c = people.get(b["customer_id"]) if b else None
        out.append({"id": r["id"], "booking_id": r["booking_id"], "booking_number": b["booking_number"] if b else None, "booking_status": b["status"] if b else None,
                    "service_name": b["service_name"] if b else None, "vendor_name": b.get("vendor_name") if b else None,
                    "customer": {"full_name": c.get("full_name"), "phone": c.get("phone")} if c else None, "pickup": sv.pickup_out(r),
                    "preferred": sv.schedule(b["preferred_date"], b["preferred_slot_start"], b["preferred_slot_end"]) if b else {"date": None, "slot_start": None, "slot_end": None},
                    "_vendor_id": b["vendor_id"] if b else None})
    return out



