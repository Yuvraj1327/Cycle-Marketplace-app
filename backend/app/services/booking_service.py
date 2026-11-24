"""Customer service bookings. Identity comes from the session; the PRICE is read by the database function, the SLOT is validated here
against the vendor's real opening hours and capacity, addresses must be the customer's own."""
from __future__ import annotations

import re
from uuid import UUID

from app.core.config import get_settings
from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict, unprocessable
from app.integrations.supabase import delete_storage_object, private_object_info
from app.repositories.address_repository import AddressRepository
from app.repositories.booking_repository import BookingRepository, ServiceGateway
from app.repositories.commerce_config_repository import SettingsStore
from app.repositories.service_repository import VendorServiceRepository
from app.schemas.booking import BookingCreate, ImageRegister
from app.services import _catalog
from app.services import _service_views as sv
from app.services._booking_builder import BUCKET, BookingBuilder
from app.services.service_catalog_service import compute_availability, local_now
from app.services.service_settings import KEYS, ServiceSettings, load_service_settings

ALLOWED_TYPES = {"image/jpeg", "image/png", "image/webp"}
_FILE = re.compile(r"^[A-Za-z0-9_\-. ]{1,120}\.(jpg|jpeg|png|webp)$", re.IGNORECASE)
REASONS = {"service_unavailable": 409, "vendor_unavailable": 409}


class BookingService:
    def __init__(self, db, admin_db):
        self.bookings = BookingRepository(db)
        self.services = VendorServiceRepository(db)
        self.booked = VendorServiceRepository(admin_db)
        self.addresses = AddressRepository(db)
        self.gateway = ServiceGateway(admin_db)
        self.store = SettingsStore(admin_db)
        self.db = db

    # ---------------- settings / builder
    def cfg(self) -> ServiceSettings:
        return load_service_settings(self.store.get_many(KEYS))

    def builder(self) -> BookingBuilder:
        return BookingBuilder(self.db, self.cfg())

    def options(self) -> dict:
        c = self.cfg()
        return {"pickup_charge": c.pickup_charge, "dropoff_charge": c.dropoff_charge, "charges_configured": c.charges_configured,
                "min_notice_hours": c.min_notice_hours, "max_advance_days": c.max_advance_days}

    # ---------------- create
    def create(self, user: CurrentUser, body: BookingCreate) -> dict:
        cfg = self.cfg()
        service = self.services.find(str(body.service_id))           # RLS: only active services of approved vendors are visible to customers
        if service is None or not service["is_active"]:
            raise NotFoundError("Service not found.")
        vendor = next(iter(self.services.vendors_public([service["vendor_id"]])), None)
        slot = self._validate_slot(service, vendor, body, cfg)
        payload = {
            "customer_id": user.id, "service_id": service["id"], "cycle_brand": body.cycle_brand, "cycle_model": body.cycle_model, "cycle_details": body.cycle_details,
            "issue_description": body.issue_description, "preferred_date": body.preferred_date.isoformat(), "slot_start": slot["start"], "slot_end": slot["end"],
            "needs_pickup_dropoff": body.needs_pickup_dropoff,
        }
        if body.needs_pickup_dropoff:
            payload.update(self._logistics(user, body, vendor, cfg))
        result = self.gateway.create_booking(payload)
        return self.get(user, UUID(result["booking_id"]))

    def _validate_slot(self, service: dict, vendor: dict | None, body: BookingCreate, cfg: ServiceSettings) -> dict:
        counts: dict[str, int] = {}
        for r in self.booked.booked_counts(service["id"], body.preferred_date.isoformat()):
            counts[sv.hhmm(r["confirmed_slot_start"])] = counts.get(sv.hhmm(r["confirmed_slot_start"]), 0) + 1
        avail = compute_availability(service, vendor, body.preferred_date, counts, cfg, now_local=local_now())
        if avail["reason"] and not avail["slots"]:
            code = avail["reason"]
            raise (conflict if code in REASONS else unprocessable)(code if code in REASONS else "slot_unavailable", f"This service cannot be booked for that date ({code.replace('_', ' ')}).")
        match = next((s for s in avail["slots"] if s["start"] == body.slot_start), None)
        if match is None:
            raise unprocessable("invalid_slot", "Choose one of the slots returned by the availability endpoint for that date.", details=[{"slots": [s["start"] for s in avail["slots"]]}])
        if not match["available"]:
            raise conflict("slot_full", "That time slot is already fully booked. Please choose another.")
        return match

    def _address(self, user: CurrentUser, address_id: UUID, kinds: tuple[str, ...], label: str) -> dict:
        row = self.addresses.find_for_user(str(address_id), user.id)
        if row is None:
            raise unprocessable("invalid_address", f"The {label} address must be one of your saved addresses.")
        if row["address_type"] not in kinds:
            raise unprocessable("invalid_address", f"That address is not saved as a {label} address.")
        return row

    def _logistics(self, user: CurrentUser, body: BookingCreate, vendor: dict | None, cfg: ServiceSettings) -> dict:
        if not vendor or not vendor.get("pickup_available"):
            raise unprocessable("pickup_not_offered", "This provider does not offer doorstep pickup.")
        pickup = self._address(user, body.pickup_address_id, ("pickup", "both"), "pickup")
        drop = self._address(user, body.dropoff_address_id, ("delivery", "both"), "drop-off") if body.dropoff_address_id else pickup
        area = vendor.get("service_area_postal_codes") or []
        for label, a in (("pickup", pickup), ("drop-off", drop)):
            if area and a["postal_code"] not in area:
                raise unprocessable("outside_service_area", f"The {label} address is outside this provider's service area.", details=[{"postal_code": a["postal_code"]}])
        snap = lambda a: {k: a.get(k) for k in ("recipient_name", "phone", "address_line1", "address_line2", "landmark", "city", "state", "postal_code", "country")}  # noqa: E731
        zero = "0.00"
        return {"pickup_address_id": pickup["id"], "pickup_address": snap(pickup), "dropoff_address_id": drop["id"], "dropoff_address": snap(drop),
                "pickup_charge": str(cfg.pickup_charge) if cfg.pickup_charge is not None else zero, "dropoff_charge": str(cfg.dropoff_charge) if cfg.dropoff_charge is not None else zero,
                "customer_instructions": body.pickup_instructions}

    # ---------------- reads
    def list(self, user: CurrentUser, *, status, page: int, limit: int) -> dict:
        rows, total = self.bookings.search(customer_id=user.id, status=status, page=page, limit=limit)
        return _catalog.page([sv.summary(r) for r in rows], total, page, limit)

    def get(self, user: CurrentUser, booking_id: UUID) -> dict:
        b = self._own(user, booking_id)
        return self.builder().detail(b, user.access_token, can_cancel=b["status"] in sv.OPEN)

    def tracking(self, user: CurrentUser, booking_id: UUID) -> dict:
        return self.builder().tracking(self._own(user, booking_id))

    def cancel(self, user: CurrentUser, booking_id: UUID, reason: str) -> dict:
        b = self._own(user, booking_id)
        if b["status"] not in sv.OPEN:
            raise conflict("invalid_transition", f"A booking that is {b['status'].replace('_', ' ')} can no longer be cancelled.")
        self.gateway.transition(b["id"], None, "cancelled", user.id, "customer", reason)
        return self.get(user, booking_id)

    # ---------------- images (files go straight to Storage; only references are stored)
    def add_image(self, user: CurrentUser, booking_id: UUID, body: ImageRegister) -> dict:
        b = self._own(user, booking_id)
        if b["status"] != "pending":
            raise conflict("images_locked", "Photos can only be added while the booking is waiting for the provider's response.")
        parts = body.storage_path.split("/")
        if not (len(parts) == 3 and parts[0] == user.id and parts[1] == b["id"] and _FILE.match(parts[2]) and ".." not in body.storage_path):
            raise unprocessable("invalid_image_path", f"storage_path must look like '{user.id}/{b['id']}/<file>.jpg|png|webp'.")
        existing = self.bookings.images(b["id"])
        if len(existing) >= get_settings().max_booking_images:
            raise conflict("image_limit", f"A booking can have at most {get_settings().max_booking_images} photos.")
        if any(i["storage_path"] == body.storage_path for i in existing):
            raise conflict("duplicate_image", "That photo is already attached.")
        info = private_object_info(user.access_token, BUCKET, body.storage_path)
        if info is None:
            raise unprocessable("image_not_uploaded", "No file was found at that path. Upload it to Storage first.")
        content_type, size = info
        if content_type and content_type not in ALLOWED_TYPES:
            raise unprocessable("unsupported_image_type", "Only JPEG, PNG or WebP images are allowed.")
        if size > get_settings().max_image_bytes:
            raise unprocessable("image_too_large", f"Images must be at most {get_settings().max_image_bytes // (1024 * 1024)} MB.")
        row = self.bookings.add_image({"booking_id": b["id"], "storage_path": body.storage_path, "uploaded_by": user.id})
        return {"id": row["id"], "storage_path": row["storage_path"], "url": None}

    def remove_image(self, user: CurrentUser, booking_id: UUID, image_id: UUID) -> None:
        b = self._own(user, booking_id)
        if b["status"] != "pending":
            raise conflict("images_locked", "Photos can no longer be removed.")
        img = self.bookings.find_image(b["id"], str(image_id))
        if img is None:
            raise NotFoundError("Image not found.")
        delete_storage_object(user.access_token, BUCKET, img["storage_path"])
        self.bookings.delete_image(img["id"])

    def _own(self, user: CurrentUser, booking_id: UUID) -> dict:
        b = self.bookings.find(str(booking_id), customer_id=user.id)
        if b is None:
            raise NotFoundError("Booking not found.")       # same answer for missing and for someone else's booking
        return b
