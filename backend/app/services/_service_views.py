"""API views of services and bookings built from stored rows only (snapshots), so history stays correct after vendors edit services."""
from decimal import Decimal
from typing import Any

from app.core.money import ZERO, q2
from app.integrations.supabase import public_storage_url
from app.repositories.base import Row

PICKUP_STAGE = {"pending": "requested", "scheduled": "scheduled", "completed": "picked_up", "failed": "failed", "cancelled": "cancelled"}
DELIVERY_STAGE = {"pending": "requested", "scheduled": "scheduled", "completed": "delivered", "failed": "failed", "cancelled": "cancelled"}
OPEN = ("pending", "accepted")


def hhmm(t: Any) -> str | None:
    return str(t)[:5] if t else None


def schedule(d, start, end) -> dict[str, Any]:
    return {"date": d, "slot_start": hhmm(start), "slot_end": hhmm(end)}


def category_image(row: Row) -> str | None:
    return public_storage_url("banners", row["image_path"]) if row.get("image_path") else None


def category_ref(c: Row | None) -> dict | None:
    return {"id": c["id"], "name": c["name"], "slug": c["slug"]} if c else None


def provider(v: Row | None) -> dict | None:
    if not v:
        return None
    return {"id": v["id"], "business_name": v["business_name"], "city": v.get("city"), "state": v.get("state"), "pickup_available": bool(v.get("pickup_available")),
            "service_area_postal_codes": v.get("service_area_postal_codes") or [], "service_radius_km": v.get("service_radius_km"),
            "operating_hours": v.get("operating_hours") or {}}


def service_public(s: Row, cats: dict[str, Row], vendors: dict[str, Row]) -> dict[str, Any]:
    keys = ("id", "name", "description", "price", "estimated_duration_minutes", "is_available", "available_days", "slot_minutes", "created_at")
    return {**{k: s.get(k) for k in keys}, "category": category_ref(cats.get(s["service_category_id"])), "provider": provider(vendors.get(s["vendor_id"]))}


def service_owner(s: Row, cats: dict[str, Row]) -> dict[str, Any]:
    keys = ("id", "service_category_id", "name", "description", "price", "estimated_duration_minutes", "is_active", "is_available", "available_days",
            "slot_minutes", "max_bookings_per_slot", "created_at", "updated_at")
    return {**{k: s.get(k) for k in keys}, "category": category_ref(cats.get(s["service_category_id"]))}


def pickup_out(r: Row | None) -> dict[str, Any] | None:
    if not r:
        return None
    keys = ("id", "pickup_address", "dropoff_address", "pickup_status", "delivery_status", "scheduled_pickup_at", "scheduled_delivery_at", "picked_up_at", "delivered_at",
            "pickup_charge", "dropoff_charge", "customer_instructions", "notes")
    return {**{k: r.get(k) for k in keys}, "pickup_stage": PICKUP_STAGE[r["pickup_status"]], "delivery_stage": DELIVERY_STAGE[r["delivery_status"]]}


def pricing(b: Row, pickup: Row | None, charges: list[Row], charges_configured: bool | None) -> dict[str, Any]:
    estimate = q2(b["estimated_price"])
    extra = sum((q2(c["amount"]) for c in charges), Decimal(0)) if charges else ZERO
    current = estimate + extra
    pc, dc = (q2(pickup["pickup_charge"]), q2(pickup["dropoff_charge"])) if pickup else (ZERO, ZERO)
    return {"estimated_price": estimate, "additional_charges_total": extra, "current_price": current, "pickup_charge": pc, "dropoff_charge": dc,
            "total_estimated": estimate + pc + dc, "total_current": current + pc + dc, "logistics_charges_configured": charges_configured if pickup else None}


def summary(b: Row, current_price: Decimal | None = None) -> dict[str, Any]:
    price = current_price if current_price is not None else q2(b["final_price"] if b.get("final_price") is not None else b["estimated_price"])
    return {"id": b["id"], "booking_number": b["booking_number"], "status": b["status"], "service_name": b["service_name"], "vendor_name": b.get("vendor_name"),
            "preferred": schedule(b["preferred_date"], b["preferred_slot_start"], b["preferred_slot_end"]),
            "confirmed": schedule(b.get("confirmed_date"), b.get("confirmed_slot_start"), b.get("confirmed_slot_end")),
            "needs_pickup_dropoff": b["needs_pickup_dropoff"], "current_price": price, "created_at": b["created_at"]}


def charge_out(c: Row) -> dict[str, Any]:
    return {"id": c["id"], "amount": c["amount"], "reason": c["reason"], "recorded_role": c.get("recorded_role"), "created_at": c["created_at"]}


def note_out(n: Row) -> dict[str, Any]:
    return {"id": n["id"], "author_role": n["author_role"], "note": n["note"], "created_at": n["created_at"]}


def detail(b: Row, *, pickup: Row | None, charges: list[Row], notes: list[Row], images: list[dict], category: Row | None, vendor: dict | None,
           charges_configured: bool | None, can_cancel: bool) -> dict[str, Any]:
    pr = pricing(b, pickup, charges, charges_configured)
    return {**summary(b, pr["current_price"]), "service_id": b.get("vendor_service_id"), "service_category": category_ref(category), "vendor": vendor,
            "cycle": {"brand": b.get("cycle_brand"), "model": b.get("cycle_model"), "details": b.get("cycle_details")}, "issue_description": b["issue_description"],
            "estimated_duration_minutes": b.get("estimated_duration_minutes"), "pricing": pr, "pickup": pickup_out(pickup),
            "charges": [charge_out(c) for c in charges], "notes": [note_out(n) for n in notes], "images": images,
            "rejection_reason": b.get("rejection_reason"), "cancellation_reason": b.get("cancellation_reason"), "completion_notes": b.get("completion_notes"),
            "accepted_at": b.get("accepted_at"), "completed_at": b.get("completed_at"), "can_cancel": can_cancel}
