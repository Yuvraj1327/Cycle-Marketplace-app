"""Shared by customer, vendor and admin booking services: assembles a BookingDetail from stored rows. Image URLs are signed AS THE VIEWER,
so storage RLS (owner / assigned vendor / admin) decides who gets a usable link."""
from __future__ import annotations

from app.integrations.supabase import create_signed_url
from app.repositories.booking_repository import BookingRepository
from app.repositories.service_repository import VendorServiceRepository
from app.services import _service_views as sv
from app.services.service_settings import ServiceSettings

BUCKET = "service-images"


class BookingBuilder:
    def __init__(self, db, cfg: ServiceSettings):
        self.bookings = BookingRepository(db)
        self.services = VendorServiceRepository(db)
        self.cfg = cfg

    def images(self, booking_id: str, token: str) -> list[dict]:
        return [{"id": i["id"], "storage_path": i["storage_path"], "url": create_signed_url(token, BUCKET, i["storage_path"]) if token else None}
                for i in self.bookings.images(booking_id)]

    def detail(self, b: dict, token: str, *, can_cancel: bool) -> dict:
        pickup = next(iter(self.bookings.pickups_for([b["id"]])), None)
        cats = {c["id"]: c for c in self.services.categories_by_ids([b["service_category_id"]])} if b.get("service_category_id") else {}
        vendors = self.services.vendors_public([b["vendor_id"]])
        vendor = sv.provider(vendors[0]) if vendors else {"id": b["vendor_id"], "business_name": b.get("vendor_name")}
        return sv.detail(b, pickup=pickup, charges=self.bookings.charges(b["id"]), notes=self.bookings.notes(b["id"]), images=self.images(b["id"], token),
                         category=cats.get(b.get("service_category_id")), vendor=vendor, charges_configured=self.cfg.charges_configured, can_cancel=can_cancel)

    def tracking(self, b: dict) -> dict:
        pickup = next(iter(self.bookings.pickups_for([b["id"]])), None)
        charges = self.bookings.charges(b["id"])
        s = sv.summary(b)
        timeline = [{"at": h["created_at"], "from_status": h.get("from_status"), "to_status": h["to_status"], "note": h.get("note"),
                     "by_role": "customer" if h.get("changed_by") == b["customer_id"] else None} for h in self.bookings.history(b["id"])]
        return {"booking_id": b["id"], "booking_number": b["booking_number"], "status": b["status"], "preferred": s["preferred"], "confirmed": s["confirmed"],
                "pickup": sv.pickup_out(pickup), "estimated_duration_minutes": b.get("estimated_duration_minutes"),
                "pricing": sv.pricing(b, pickup, charges, self.cfg.charges_configured), "timeline": timeline, "charges": [sv.charge_out(c) for c in charges],
                "notes": [sv.note_out(n) for n in self.bookings.notes(b["id"])], "completed_at": b.get("completed_at"), "completion_notes": b.get("completion_notes")}
