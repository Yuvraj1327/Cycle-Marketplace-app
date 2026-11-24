"""DEV/TEST HARNESS ONLY - not part of the product.

Boots the REAL FastAPI application with the in-memory database used by the test-suite, a test payment provider (HMAC, not a real gateway) and
locally signed Supabase-style JWTs, seeded with realistic marketplace + servicing data. The Flutter app's contract tests talk to it over real HTTP,
so they exercise the real routers, validation, services and response schemas (but NOT a real Supabase/PostgREST/Storage).

    python -m tests.dev_server            # serves on :8791, tokens at GET /__dev/tokens
"""
import os
import sys
import time
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

os.environ.update(SUPABASE_URL="https://testproj.supabase.co", SUPABASE_ANON_KEY="anon-placeholder", SUPABASE_SERVICE_ROLE_KEY="service-placeholder")

import jwt  # noqa: E402
import uvicorn  # noqa: E402
from types import SimpleNamespace  # noqa: E402

import app.integrations.supabase as sb  # noqa: E402
import app.services._booking_builder as builder  # noqa: E402
import app.services.booking_service as booking_service  # noqa: E402
import app.services.product_image_service as product_image_service  # noqa: E402
from app.core import dependencies as deps  # noqa: E402
from app.core import security  # noqa: E402
from app.main import app  # noqa: E402
from tests.conftest import _PRIVATE, ISSUER, SERVICE, FakeClient, FakeDB, FakeProvider  # noqa: E402

PORT = int(os.environ.get("DEV_PORT", "8791"))
db = FakeDB()
provider = FakeProvider()
storage = {"uploaded": set()}


class _Jwks:
    def get_signing_key_from_jwt(self, _):
        return SimpleNamespace(key=_PRIVATE.public_key())


security._jwks_client = lambda *a, **k: _Jwks()
deps.create_user_db_client = lambda token: FakeClient(db, jwt.decode(token, options={"verify_signature": False})["sub"])
deps.create_anon_db_client = lambda: FakeClient(db, None)
deps.create_admin_db_client = lambda: FakeClient(db, SERVICE)
app.dependency_overrides[deps.get_provider] = lambda: provider
booking_service.private_object_info = lambda t, b, p: ("image/jpeg", 1000) if p in storage["uploaded"] else None
booking_service.delete_storage_object = lambda t, b, p: None
product_image_service.head_public_object = lambda b, p: (200, "image/jpeg", 1000) if p in storage["uploaded"] else None
product_image_service.delete_storage_object = lambda t, b, p: None
builder.create_signed_url = lambda token, bucket, path, expires_in=3600: f"https://signed.example/{bucket}/{path}"
sb.public_storage_url = sb.public_storage_url      # public URLs are plain strings; real hostnames are irrelevant here


def token(uid: str, exp_in: int = 3600) -> str:
    now = int(time.time())
    return jwt.encode({"sub": uid, "aud": "authenticated", "iss": ISSUER, "role": "authenticated", "iat": now, "exp": now + exp_in, "email": f"{uid[:6]}@example.com",
                       "phone": "", "session_id": "s", "aal": "aal1"}, _PRIVATE, algorithm="RS256", headers={"kid": "k1"})


def seed() -> dict:
    hours = {d: {"open": "09:00", "close": "18:00"} for d in ("mon", "tue", "wed", "thu", "fri", "sat", "sun")}
    ua, va = db.add_approved_vendor("Spoke & Co")
    va.update(pickup_available=True, operating_hours=hours, service_area_postal_codes=["411001", "411002"], city="Pune", state="Maharashtra")
    ub, vb = db.add_approved_vendor("Gear Garage")
    vb.update(pickup_available=False, operating_hours=hours, city="Mumbai", state="Maharashtra")
    cats = {k: db.add_category(k, n, sort_order=i) for i, (k, n) in enumerate([("new_cycle", "New Cycles"), ("used_cycle", "Used Cycles"), ("spare_part", "Spare Parts"), ("accessory", "Accessories")])}
    prods = {}
    specs = [("Trail Blazer 29", "new_cycle", "Hero", "TB-29", 24999.0, 6, True), ("City Cruiser", "new_cycle", "Firefox", "CC-1", 14500.0, 3, False),
             ("Old Commuter", "used_cycle", "Atlas", "C2", 4200.0, 1, False), ("Disc Brake Set", "spare_part", "Shimano", "BR-M315", 1850.0, 10, True),
             ("Road Helmet", "accessory", "Giro", "H-9", 2999.0, 0, False)]
    for i, (name, kind, brand, model, price, stock, feat) in enumerate(specs):
        vendor = va if i % 2 == 0 else vb
        p = db.add_product(vendor["id"], cats[kind], name=name, brand=brand, model=model, price=price, stock_quantity=stock, is_featured=feat,
                           description=f"{name} by {brand}. Quality checked.", specifications={"Frame": "Alloy", "Gears": 21}, created_at=f"2026-03-0{i + 1}T00:00:00+00:00")
        db.add_image(p["id"], f"{vendor['user_id']}/{p['id']}/1.jpg", is_primary=True)
        prods[name] = p
    for i, (title, kind) in enumerate([("Monsoon Service Offer", "none"), ("New Arrivals", "category")]):
        db.rows("banners").append(db.apply_defaults("banners", {"title": title, "subtitle": "Limited time", "image_path": f"banners/b{i}.jpg", "action_type": kind,
                                                                "action_value": cats["new_cycle"]["id"] if kind == "category" else None, "sort_order": i}))
    scat = [db.apply_defaults("service_categories", {"name": n, "slug": n.lower().replace(" ", "-"), "sort_order": i, "description": f"{n} for every cycle"})
            for i, n in enumerate(["General Servicing", "Puncture Repair", "Brake Repair", "Gear Adjustment", "Parts Replacement"])]
    db.rows("service_categories").extend(scat)
    svc = db.apply_defaults("vendor_services", {"vendor_id": va["id"], "service_category_id": scat[0]["id"], "name": "Full service", "price": 499.0,
                                               "estimated_duration_minutes": 120, "description": "Complete tune-up and safety check"})
    db.rows("vendor_services").append(svc)
    cust, other, admin = db.add_profile(full_name="Asha Rao", phone="+919800000001"), db.add_profile(full_name="Other Customer"), db.add_profile(role="admin")
    addr = db.apply_defaults("user_addresses", {"user_id": cust, "recipient_name": "Asha Rao", "phone": "+919800000001", "address_line1": "12 MG Road", "city": "Pune",
                                               "state": "Maharashtra", "postal_code": "411001", "address_type": "both", "is_default": True, "label": "Home"})
    db.rows("user_addresses").append(addr)
    db.rows("carts").append(db.apply_defaults("carts", {"user_id": cust}))
    db.rows("platform_settings").append({"key": "payments.cod_enabled", "value": True})
    db.rows("commission_rules").append(db.apply_defaults("commission_rules", {"name": "Global", "applies_to": "product", "commission_type": "percentage", "commission_value": 10}))
    db.rows("coupons").append(db.apply_defaults("coupons", {"code": "WELCOME10", "discount_type": "percentage", "discount_value": 10, "max_discount_amount": 500}))
    for t in ("Order placed", "Booking accepted"):
        db.rows("notifications").append(db.apply_defaults("notifications", {"user_id": cust, "type": "order", "title": t, "message": f"{t} - details", "related_type": "order",
                                                                           "related_id": str(uuid.uuid4()), "is_read": False, "read_at": None}))
    # vendor accounts in every lifecycle state (Vendor App contract tests)
    states = {}
    for key, status, extra in (("pending", "pending", {}), ("rejected", "rejected", {"rejection_reason": "Shop photos were unclear"}), ("suspended", "suspended", {})):
        uid = db.add_profile(role="vendor", full_name=f"{key.title()} Vendor")
        db.add_vendor(uid, status, business_name=f"{key.title()} Cycles", **extra)
        states[f"vendor_{key}"] = uid
    states["vendor_new"] = db.add_profile(role="vendor", full_name="New Vendor")      # signed up as vendor, no business yet
    db.rows("notifications").append(db.apply_defaults("notifications", {"user_id": ua, "type": "service_booking", "title": "New booking", "message": "A booking awaits",
                                                                       "related_type": "service_booking", "related_id": str(uuid.uuid4()), "is_read": False, "read_at": None}))
    today = datetime.now(ZoneInfo("Asia/Kolkata")).date()
    return {**states, "vendor_b_user": ub, "vendor_b_id": vb["id"], "customer": cust, "other": other, "admin": admin, "vendor_user": ua, "vendor_id": va["id"], "service_id": svc["id"], "address_id": addr["id"],
            "category_ids": {k: c["id"] for k, c in cats.items()}, "product_ids": {n: p["id"] for n, p in prods.items()}, "service_category_id": scat[0]["id"],
            "day": (today + timedelta(days=3)).isoformat(), "coupon": "WELCOME10"}


@app.get("/__dev/tokens", include_in_schema=False)
def tokens():
    ids = SEED
    return {**ids, "tokens": {k: token(ids[k]) for k in ("customer", "other", "admin", "vendor_user", "vendor_b_user", "vendor_pending", "vendor_rejected", "vendor_suspended", "vendor_new")}, "expired": token(ids["customer"], -3600),
            "storage_note": "service-images uploads are simulated via POST /__dev/upload"}


@app.post("/__dev/upload", include_in_schema=False)
def upload(path: str):
    storage["uploaded"].add(path)
    return {"uploaded": path}


@app.post("/__dev/reset", include_in_schema=False)
def reset():
    global SEED
    db.tables.clear()
    db.sql.calls.clear()
    SEED = seed()
    return {"ok": True}


SEED = seed()

if __name__ == "__main__":
    print(f"READY http://127.0.0.1:{PORT}", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
