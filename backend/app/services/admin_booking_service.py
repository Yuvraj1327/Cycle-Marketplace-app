from __future__ import annotations

from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict, unprocessable
from app.core.search import contains_pattern, sanitize_term
from app.repositories.admin_ops_repository import DirectoryRepository
from app.repositories.admin_user_repository import AdminNotifier
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
        self.people = DirectoryRepository(db)
        self.notifier = AdminNotifier(admin_db)

    # ---------------- bookings
    def _search_expr(self, term: str) -> str:
        """booking number, OR the customer (name / e-mail / phone), OR the provider's business name."""
        clauses = [f"booking_number.ilike.{contains_pattern(term)}"]
        customers = self.people.customer_ids_matching(term)
        if customers:
            clauses.append(f"customer_id.in.({','.join(customers)})")
        vendors = self.people.vendor_ids_matching(term)
        if vendors:
            clauses.append(f"vendor_id.in.({','.join(vendors)})")
        return ",".join(clauses)

    def list(self, *, status, vendor_id, customer_id, date_from, date_to, q, page: int, limit: int) -> dict:
        term = sanitize_term(q or "", 40, allow_at=True) or None
        if q and not term:
            return _catalog.page([], 0, page, limit)
        rows, total = self.bookings.search(vendor_id=str(vendor_id) if vendor_id else None, customer_id=str(customer_id) if customer_id else None, status=status,
                                           date_from=date_from.isoformat() if date_from else None, date_to=date_to.isoformat() if date_to else None,
                                           or_expr=self._search_expr(term) if term else None, page=page, limit=limit)
        items = list_items(self.bookings, rows, admin=True)
        cats = {c["id"]: c["name"] for c in self.services.categories_by_ids(sorted({r["service_category_id"] for r in rows if r.get("service_category_id")}))}
        by_id = {r["id"]: r for r in rows}
        return _catalog.page([{**i, "service_category": cats.get((by_id.get(i["id"]) or {}).get("service_category_id"))} for i in items], total, page, limit)

    def get(self, booking_id: UUID, token: str = "") -> dict:
        b = self.bookings.find(str(booking_id))
        if b is None:
            raise NotFoundError("Booking not found.")
        cfg = load_service_settings(self.store.get_many(KEYS))
        out = BookingBuilder(self.db, cfg).detail(b, token, can_cancel=False)
        vendor = next(iter(self.bookings.vendor_profiles([b["vendor_id"]])), None)
        return {**out, "customer": customer_brief(self.bookings, b["customer_id"]), "customer_id": b["customer_id"], "vendor_admin": vendor}

    def timeline(self, booking_id: UUID) -> list[dict]:
        """The repair/booking status history, oldest first, with who made each change."""
        b = self.bookings.find(str(booking_id))
        if b is None:
            raise NotFoundError("Booking not found.")
        rows = self.bookings.history(b["id"])
        people = self.people.profiles([r["changed_by"] for r in rows if r.get("changed_by")], "id,full_name,role")
        return [{"at": h["created_at"], "scope": "booking", "from_status": h.get("from_status"), "to_status": h["to_status"], "note": h.get("note"),
                 "changed_by_id": h.get("changed_by"), "changed_by_name": (people.get(h.get("changed_by")) or {}).get("full_name"),
                 "changed_by_role": (people.get(h.get("changed_by")) or {}).get("role")} for h in rows]

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
    def list_pickups(self, *, pickup_status, delivery_status, page: int, limit: int, q=None) -> dict:
        term = sanitize_term(q or "", 40, allow_at=True) or None
        if q and not term:
            return _catalog.page([], 0, page, limit)
        booking_ids = None
        if term:
            booking_ids = [b["id"] for b in self.bookings.search(or_expr=self._search_expr(term), page=1, limit=500)[0]]
        rows, total = self.bookings.list_pickups(booking_ids=booking_ids, pickup_status=pickup_status, delivery_status=delivery_status, page=page, limit=limit)
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
    def list_services(self, *, vendor_id, category_id, is_active, q, page: int, limit: int, is_available=None) -> dict:
        term = sanitize_term(q or "", 60) or None
        rows, total = self.services.search(vendor_id=str(vendor_id) if vendor_id else None, category_id=str(category_id) if category_id else None, is_active=is_active,
                                           is_available=is_available, q_name=term, page=page, limit=limit)
        return _catalog.page(self._service_views(rows), total, page, limit)

    def get_service(self, service_id: UUID) -> dict:
        row = self.services.find(str(service_id))
        if row is None:
            raise NotFoundError("Service not found.")
        return self._service_views([row])[0]

    def set_service_status(self, admin: CurrentUser, service_id: UUID, is_active: bool, reason: str | None) -> dict:
        """Deactivate (or re-activate) a vendor's service. The listing, its price and all bookings are preserved; the vendor is told why.
        A vendor can still re-activate their own service - to stop a vendor altogether, suspend the vendor."""
        row = self.services.find(str(service_id))
        if row is None:
            raise NotFoundError("Service not found.")
        if row["is_active"] == is_active:
            raise conflict("no_change", f"This service is already {'active' if is_active else 'inactive'}.")
        self.services.modify_as_admin(str(service_id), {"is_active": is_active})
        self.audit.record(admin.id, "service_activated" if is_active else "service_deactivated", "vendor_service", str(service_id), {"reason": reason, "name": row["name"]})
        owner = self.people.vendor_user_id(row["vendor_id"])
        if owner:
            try:
                text = (f"Service '{row['name']}' was deactivated", f"The administrator deactivated this service. Reason: {reason}") if not is_active else \
                       (f"Service '{row['name']}' was re-activated", "The administrator re-activated this service.")
                self.notifier.notify(owner, text[0], text[1], str(service_id), related_type="vendor_service")
            except Exception:       # the change is stored; a failed notification must not hide it
                pass
        return self.get_service(service_id)

    def _service_views(self, rows: list[dict]) -> list[dict]:
        cats = {c["id"]: c for c in self.services.categories_by_ids(sorted({r["service_category_id"] for r in rows}))}
        vendors = {v["id"]: v for v in self.bookings.vendor_profiles(sorted({r["vendor_id"] for r in rows}))}
        return [{**sv.service_owner(r, cats), "vendor_id": r["vendor_id"], "vendor_name": (vendors.get(r["vendor_id"]) or {}).get("business_name"),
                 "vendor_status": (vendors.get(r["vendor_id"]) or {}).get("verification_status")} for r in rows]


def _strip(item: dict) -> dict:
    item.pop("_vendor_id", None)
    return item
