"""Customer-facing service discovery + availability. Reads run on the anonymous client (RLS: active services of approved vendors only)."""
from __future__ import annotations

from datetime import date, datetime
from uuid import UUID
from zoneinfo import ZoneInfo

from app.core.config import get_settings
from app.core.exceptions import NotFoundError
from app.core.search import sanitize_term
from app.repositories.service_repository import VendorServiceRepository
from app.services import _catalog
from app.services import _scheduling as sch
from app.services import _service_views as sv


class ServiceCatalogService:
    def __init__(self, db, admin_db=None, settings=None):
        self.repo = VendorServiceRepository(db)
        self.booked_repo = VendorServiceRepository(admin_db) if admin_db is not None else None
        self.settings = settings

    def list(self, *, category_id, vendor_id, q, page: int, limit: int) -> dict:
        term = sanitize_term(q or "", 60) or None
        if q and not term:
            return _catalog.page([], 0, page, limit)
        rows, total = self.repo.search(category_id=str(category_id) if category_id else None, vendor_id=str(vendor_id) if vendor_id else None, active_only=True,
                                       q_name=term, page=page, limit=limit)
        return _catalog.page(self._views(rows), total, page, limit)

    def get(self, service_id: UUID) -> dict:
        row = self._public(service_id)
        return self._views([row])[0]

    def availability(self, service_id: UUID, day: date) -> dict:
        service = self._public(service_id)
        vendor = {v["id"]: v for v in self.repo.vendors_public([service["vendor_id"]])}.get(service["vendor_id"])
        booked = self._booked(service["id"], day)
        return compute_availability(service, vendor, day, booked, self.settings, now_local=local_now())

    # ---------------- helpers
    def _public(self, service_id: UUID) -> dict:
        row = self.repo.find(str(service_id))
        if row is None or not row["is_active"]:          # anon RLS already hides inactive services / unapproved vendors
            raise NotFoundError("Service not found.")
        return row

    def _booked(self, service_id: str, day: date) -> dict[str, int]:
        counts: dict[str, int] = {}
        if self.booked_repo is not None:
            for r in self.booked_repo.booked_counts(service_id, day.isoformat()):
                key = sv.hhmm(r["confirmed_slot_start"])
                counts[key] = counts.get(key, 0) + 1
        return counts

    def _views(self, rows: list[dict]) -> list[dict]:
        cats = {c["id"]: c for c in self.repo.categories_by_ids(sorted({r["service_category_id"] for r in rows}))}
        vendors = {v["id"]: v for v in self.repo.vendors_public(sorted({r["vendor_id"] for r in rows}))}
        return [sv.service_public(r, cats, vendors) for r in rows]


def local_now() -> datetime:
    return datetime.now(ZoneInfo(get_settings().business_timezone))


def compute_availability(service: dict, vendor: dict | None, day: date, booked: dict[str, int], settings, *, now_local: datetime) -> dict:
    """Slots for one date. `reason` explains an empty list in plain codes the app can translate."""
    from app.services.service_settings import ServiceSettings
    cfg = settings or ServiceSettings()
    base = {"service_id": service["id"], "date": day, "slot_minutes": service["slot_minutes"], "slots": [], "bookable": False}
    today = now_local.date()
    if not service["is_active"] or not service["is_available"]:
        return {**base, "reason": "service_unavailable"}
    if vendor is None:
        return {**base, "reason": "vendor_unavailable"}
    if day < today:
        return {**base, "reason": "date_in_past"}
    if (day - today).days > cfg.max_advance_days:
        return {**base, "reason": "too_far_ahead"}
    days = service.get("available_days")
    if days is not None and sch.weekday_key(day) not in days:
        return {**base, "reason": "service_not_offered_that_day"}
    hours = vendor.get("operating_hours") or {}
    if not hours:
        return {**base, "reason": "vendor_hours_not_configured"}
    window = sch.opening_window(hours, day)
    if window is None:
        return {**base, "reason": "vendor_closed"}
    cap = service["max_bookings_per_slot"]
    slots = []
    for s in sch.build_slots(window, service["slot_minutes"]):
        if not sch.slot_is_bookable_time(day, s, now_local, cfg.min_notice_hours):
            continue
        n = booked.get(f"{s.start:%H:%M}", 0)
        slots.append({"start": f"{s.start:%H:%M}", "end": f"{s.end:%H:%M}", "capacity": cap, "booked": n, "available": n < cap})
    return {**base, "slots": slots, "bookable": any(s["available"] for s in slots), "reason": None if slots else "no_slots_left"}
