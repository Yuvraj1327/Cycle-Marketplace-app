from __future__ import annotations

from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, unprocessable
from app.core.search import sanitize_term
from app.repositories.booking_repository import BookingRepository, ServiceGateway
from app.repositories.commerce_config_repository import AuditRepository, SettingsStore
from app.repositories.service_repository import VendorServiceRepository
from app.schemas.booking import AdminStatusUpdate, LogisticsUpdate
from app.services import _catalog
from app.services import _service_views as sv
from app.services._booking_builder import BookingBuilder
from app.services.service_settings import KEYS, load_service_settings
from app.services.vendor_booking_service import customer_brief, list_items, logistics_changes, pickup_items


class AdminBookingService:
    """Admin reads run with the admin's own token (RLS is_admin); changes use the audited SQL functions with role='admin'."""

    def __init__(self, db, admin_db):
        self.db = db
        self.bookings = BookingRepository(db)
        self.services = VendorServiceRepository(db)
        self.gateway = ServiceGateway(admin_db)
        self.audit = AuditRepository(admin_db)
        self.store = SettingsStore(admin_db)

    # ---------------- bookings
    def list(self, *, status, vendor_id, customer_id, date_from, date_to, q, page: int, limit: int) -> dict:
        term = sanitize_term(q or "", 30) or None
        if q and not term:
            return _catalog.page([], 0, page, limit)
        rows, total = self.bookings.search(vendor_id=str(vendor_id) if vendor_id else None, customer_id=str(customer_id) if customer_id else None, status=status,
                                           date_from=date_from.isoformat() if date_from else None, date_to=date_to.isoformat() if date_to else None,
                                           number_like=term, page=page, limit=limit)
        return _catalog.page(list_items(self.bookings, rows, admin=True), total, page, limit)

    def get(self, booking_id: UUID, token: str = "") -> dict:
        b = self.bookings.find(str(booking_id))
        if b is None:
            raise NotFoundError("Booking not found.")
        cfg = load_service_settings(self.store.get_many(KEYS))
        out = BookingBuilder(self.db, cfg).detail(b, token, can_cancel=False)
        vendor = next(iter(self.bookings.vendor_profiles([b["vendor_id"]])), None)
        return {**out, "customer": customer_brief(self.bookings, b["customer_id"]), "customer_id": b["customer_id"], "vendor_admin": vendor}

    def set_status(self, admin: CurrentUser, booking_id: UUID, body: AdminStatusUpdate) -> dict:
        b = self.bookings.find(str(booking_id))
        if b is None:
            raise NotFoundError("Booking not found.")
        target = body.status.value
        if target in ("accepted", "pending"):
            raise unprocessable("unsupported_status", "Acceptance is the provider's decision; admins can move a booking forward, reject, or cancel it.")
        if target in ("rejected", "cancelled") and len((body.reason or "").strip()) < 3:
            raise unprocessable("reason_required", "A reason is required to reject or cancel a booking.")
        self.gateway.transition(b["id"], None, target, admin.id, "admin", body.reason)
        self.audit.record(admin.id, "service_booking_status_changed", "service_booking", b["id"], {"status": target, "reason": body.reason})
        return self.get(booking_id, admin.access_token)

    # ---------------- pickup / drop-off
    def list_pickups(self, *, pickup_status, delivery_status, page: int, limit: int) -> dict:
        rows, total = self.bookings.list_pickups(pickup_status=pickup_status, delivery_status=delivery_status, page=page, limit=limit)
        return _catalog.page([_strip(i) for i in pickup_items(self.bookings, rows)], total, page, limit)

    def get_pickup(self, request_id: UUID) -> dict:
        r = self.bookings.find_pickup(str(request_id))
        if r is None:
            raise NotFoundError("Pickup request not found.")
        return _strip(pickup_items(self.bookings, [r])[0])

    def update_pickup(self, admin: CurrentUser, request_id: UUID, body: LogisticsUpdate) -> dict:
        r = self.bookings.find_pickup(str(request_id))
        if r is None:
            raise NotFoundError("Pickup request not found.")
        changes = logistics_changes(body)
        self.gateway.set_logistics(r["id"], None, admin.id, "admin", changes)
        self.audit.record(admin.id, "pickup_request_coordinated", "pickup_dropoff", r["id"], changes)
        return self.get_pickup(request_id)

    # ---------------- services
    def list_services(self, *, vendor_id, category_id, is_active, q, page: int, limit: int) -> dict:
        term = sanitize_term(q or "", 60) or None
        rows, total = self.services.search(vendor_id=str(vendor_id) if vendor_id else None, category_id=str(category_id) if category_id else None, is_active=is_active, q_name=term, page=page, limit=limit)
        return _catalog.page(self._service_views(rows), total, page, limit)

    def get_service(self, service_id: UUID) -> dict:
        row = self.services.find(str(service_id))
        if row is None:
            raise NotFoundError("Service not found.")
        return self._service_views([row])[0]

    def _service_views(self, rows: list[dict]) -> list[dict]:
        cats = {c["id"]: c for c in self.services.categories_by_ids(sorted({r["service_category_id"] for r in rows}))}
        vendors = {v["id"]: v for v in self.bookings.vendor_profiles(sorted({r["vendor_id"] for r in rows}))}
        return [{**sv.service_owner(r, cats), "vendor_id": r["vendor_id"], "vendor_name": (vendors.get(r["vendor_id"]) or {}).get("business_name"),
                 "vendor_status": (vendors.get(r["vendor_id"]) or {}).get("verification_status")} for r in rows]


def _strip(item: dict) -> dict:
    item.pop("_vendor_id", None)
    return item
