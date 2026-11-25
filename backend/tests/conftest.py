import copy
import re
import time
import uuid
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.core import dependencies as deps
from app.core import security
from app.core import supabase as sb
from app.core.config import get_settings
from app.main import app

SUPABASE_URL = "https://testproj.supabase.co"
ISSUER = f"{SUPABASE_URL}/auth/v1"
_PRIVATE = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_OTHER_PRIVATE = rsa.generate_private_key(public_exponent=65537, key_size=2048)


# ---------------- in-memory PostgREST stand-in (no RLS emulation: RLS is covered by the Step 2 SQL tests) ----------
def _pg_error(code: str, msg: str) -> APIError:
    return APIError({"message": msg, "code": code, "details": None, "hint": None})


class FakeResult:
    def __init__(self, data, count=None):
        self.data, self.count = data, count


SERVICE = "service"      # service-role actor: bypasses RLS and guard triggers
ADMIN_ONLY = {"coupons", "commission_rules"}
PRIVILEGED_PRODUCT_FIELDS = ("approval_status", "is_featured", "reviewed_by", "reviewed_at", "review_notes")


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return str(x)


def _split_top(text):
    parts, depth, cur = [], 0, ""
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur); cur = ""
        else:
            cur += ch
    return parts + [cur]


def _like_regex(pattern):
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if c == "\\" and i + 1 < len(pattern):
            out += re.escape(pattern[i + 1]); i += 2; continue
        out += ".*" if c == "*" else re.escape(c)
        i += 1
    return re.compile("^" + out + "$", re.IGNORECASE | re.DOTALL)


def _clause(row, text):
    col, op, val = text.split(".", 2)
    cell = row.get(col)
    if op == "ilike":
        return cell is not None and bool(_like_regex(val).match(str(cell)))
    if op == "eq":
        return str(cell).lower() == val.lower()
    if op == "in":
        return str(cell) in val.strip("()").split(",")
    raise AssertionError(f"unsupported or_ clause {text!r}")


class FakeQuery:
    def __init__(self, db, table, actor):
        self.db, self.table_name, self.actor = db, table, actor
        self.op, self.payload, self.checks, self.orders = "select", None, [], []
        self._limit, self._range, self._count, self._head = None, None, False, False

    def select(self, *_a, count=None, head=None): self.op = "select"; self._count = count is not None; self._head = bool(head); return self
    def insert(self, values): self.op, self.payload = "insert", values; return self
    def update(self, values): self.op, self.payload = "update", values; return self
    def delete(self): self.op = "delete"; return self
    def order(self, col, desc=False): self.orders.append((col, desc)); return self
    def limit(self, n): self._limit = n; return self
    def range(self, a, b): self._range = (a, b); return self

    def _f(self, fn): self.checks.append(fn); return self
    def eq(self, c, v): return self._f(lambda r: r.get(c) == v)
    def neq(self, c, v): return self._f(lambda r: r.get(c) != v)
    def gt(self, c, v): return self._f(lambda r: r.get(c) is not None and _num(r[c]) > _num(v))
    def gte(self, c, v): return self._f(lambda r: r.get(c) is not None and _num(r[c]) >= _num(v))
    def lt(self, c, v): return self._f(lambda r: r.get(c) is not None and _num(r[c]) < _num(v))
    def lte(self, c, v): return self._f(lambda r: r.get(c) is not None and _num(r[c]) <= _num(v))
    def in_(self, c, vs): return self._f(lambda r: r.get(c) in list(vs))
    def contains(self, c, vs): return self._f(lambda r: set(vs) <= set(r.get(c) or []))
    def is_(self, c, v): return self._f(lambda r: (r.get(c) is None) == (v == "null"))
    def ilike(self, c, p): return self._f(lambda r: r.get(c) is not None and bool(_like_regex(p).match(str(r[c]))))
    @property
    def not_(self):
        outer = self

        class _Not:
            def is_(self_inner, c, v):
                return outer._f(lambda r: (r.get(c) is None) != (v == "null"))

            def in_(self_inner, c, vs):
                return outer._f(lambda r: r.get(c) not in list(vs))
        return _Not()

    def or_(self, expr):
        self.db.or_calls.append(expr)
        clauses = _split_top(expr)
        return self._f(lambda r: any(_clause(r, c) for c in clauses))

    def execute(self):
        db = self.db
        rows = db.rows(self.table_name)
        match = lambda r: all(c(r) for c in self.checks)  # noqa: E731
        if self.op == "select":
            hit = [r for r in rows if db.visible(self.table_name, r, self.actor) and match(r)]
            for col, desc in reversed(self.orders):
                hit.sort(key=lambda r: (r.get(col) is None, r.get(col)), reverse=desc)
            total = len(hit)
            if self._range:
                hit = hit[self._range[0]: self._range[1] + 1]
            if self._limit:
                hit = hit[: self._limit]
            return FakeResult([] if self._head else [copy.deepcopy(r) for r in hit], total if self._count else None)
        if self.op == "insert":
            row = db.apply_defaults(self.table_name, dict(self.payload))
            db.check_write(self.table_name, "insert", row, None, self.actor)
            db.check_unique(self.table_name, row, rows)
            rows.append(row)
            return FakeResult([copy.deepcopy(row)])
        if self.op == "update":
            hit = [r for r in rows if db.visible(self.table_name, r, self.actor) and match(r) and db.can_write_row(self.table_name, r, self.actor)]
            for r in hit:
                cand = {**r, **self.payload, "updated_at": db.now()}
                db.check_write(self.table_name, "update", cand, r, self.actor)
                db.check_unique(self.table_name, cand, [x for x in rows if x is not r])
                before = dict(r)
                r.update(cand)
                db.after_update(self.table_name, before, r)
            return FakeResult([copy.deepcopy(r) for r in hit])
        if self.op == "delete":
            hit = [r for r in rows if db.visible(self.table_name, r, self.actor) and match(r) and db.can_write_row(self.table_name, r, self.actor)]
            db.tables[self.table_name] = [r for r in rows if r not in hit]
            db.cascade_delete(self.table_name, hit)
            return FakeResult([copy.deepcopy(r) for r in hit])
        raise AssertionError(self.op)


class _Rpc:
    def __init__(self, db, actor, fn, params): self.db, self.actor, self.fn, self.params = db, actor, fn, params

    def execute(self):
        if self.actor != SERVICE:
            raise _pg_error("42501", "permission denied for function")           # every RPC is service_role only
        if self.fn == "adjust_product_stock":
            row = next((r for r in self.db.rows("products") if r["id"] == self.params["p_product_id"]), None)
            if row is None or row["stock_quantity"] + self.params["p_delta"] < 0:
                raise _pg_error("23514", "unknown product or insufficient stock")
            row["stock_quantity"] += self.params["p_delta"]
            return FakeResult(row["stock_quantity"])
        return FakeResult(self.db.sql.call(self.fn, self.params, self.actor))


class FakeClient:
    """A PostgREST client acting as `actor` (None = anon, a user id, or SERVICE)."""

    def __init__(self, db, actor): self.db, self.actor = db, actor
    def table(self, name): return FakeQuery(self.db, name, self.actor)
    def rpc(self, fn, params): return _Rpc(self.db, self.actor, fn, params)
    def aclose(self): pass


class FakeDB:
    def __init__(self):
        self.tables, self.tokens_used, self.or_calls = {}, [], []
        from tests.fake_orders import FakeOrderSQL
        from tests.fake_services import FakeServiceSQL

        class Commerce(FakeServiceSQL, FakeOrderSQL):
            pass

        self.sql = Commerce(self)

    @staticmethod
    def now():
        return "2026-01-01T00:00:00+00:00"

    def future(self, seconds):
        """A timestamp `seconds` after the (frozen) fake clock; used for push back-off."""
        from datetime import datetime, timedelta
        return (datetime.fromisoformat(self.now()) + timedelta(seconds=seconds)).isoformat()

    def age_hours(self, ts):
        """Fake notifications are all 'created' at the frozen fake clock, so they are never too old unless a test backdates `created_at`."""
        from datetime import datetime
        return (datetime.fromisoformat(self.now()) - datetime.fromisoformat(str(ts))).total_seconds() / 3600

    def rows(self, name):
        if name == "vendor_public_profiles":   # the public-safe view of approved vendors
            keep = ("id", "business_name", "business_types", "description", "city", "state", "pickup_available", "operating_hours", "service_area_postal_codes", "service_radius_km")
            return [{k: v.get(k) for k in keep} for v in self.tables.get("vendor_profiles", []) if self.vendor_ok(v["id"])]
        return self.tables.setdefault(name, [])

    def table(self, name):          # service-level access (used by Step 3 tests and the admin script)
        return FakeQuery(self, name, SERVICE)

    def aclose(self):
        pass

    # ---- role helpers
    def profile(self, uid):
        return next((p for p in self.rows("profiles") if p["id"] == uid), None)

    def role(self, actor):
        p = self.profile(actor) if actor not in (None, SERVICE) else None
        return p["role"] if p and p["status"] == "active" else None

    def vendor_of(self, uid):
        return next((v for v in self.rows("vendor_profiles") if v["user_id"] == uid), None)

    def vendor_ok(self, vendor_id):
        v = next((v for v in self.rows("vendor_profiles") if v["id"] == vendor_id), None)
        p = self.profile(v["user_id"]) if v else None
        return bool(v and v["verification_status"] == "approved" and p and p["status"] == "active")

    def approved_vendor_actor(self, actor):
        v = self.vendor_of(actor)
        return bool(v and self.vendor_ok(v["id"]))

    # ---- emulated RLS (select)
    def visible(self, table, row, actor):
        if actor == SERVICE:
            return True
        role = self.role(actor)
        if role == "admin" and table not in ("carts", "cart_items", "wishlists", "wishlist_items"):
            return True
        if table == "products":
            if row["is_active"] and row["approval_status"] == "approved" and self.vendor_ok(row["vendor_id"]):
                return True
            v = self.vendor_of(actor) if actor else None
            return bool(v and row["vendor_id"] == v["id"])
        if table == "product_images":
            prod = next((p for p in self.rows("products") if p["id"] == row["product_id"]), None)
            return bool(prod and self.visible("products", prod, actor))
        if table in ("categories", "service_categories"):
            return row["is_active"]
        if table == "vendor_services":
            v = self.vendor_of(actor) if actor else None
            return bool((row["is_active"] and self.vendor_ok(row["vendor_id"])) or (v and row["vendor_id"] == v["id"]))
        if table == "service_bookings":
            v = self.vendor_of(actor) if actor else None
            return row["customer_id"] == actor or bool(v and row["vendor_id"] == v["id"])
        if table in ("pickup_dropoff_requests", "service_booking_images", "booking_status_history", "service_charges", "service_booking_notes"):
            b = next((x for x in self.rows("service_bookings") if x["id"] == row["booking_id"]), None)
            return bool(b and self.visible("service_bookings", b, actor))
        if table == "support_tickets":
            return row["requester_id"] == actor
        if table == "banners":
            return row["is_active"] and (row.get("starts_at") is None or row["starts_at"] <= self.now()) and (row.get("ends_at") is None or row["ends_at"] > self.now())
        if table in ("carts", "wishlists"):
            return actor is not None and row["user_id"] == actor
        if table in ("cart_items", "wishlist_items"):
            parent = "carts" if table == "cart_items" else "wishlists"
            key = "cart_id" if table == "cart_items" else "wishlist_id"
            par = next((c for c in self.rows(parent) if c["id"] == row[key]), None)
            return bool(par and actor is not None and par["user_id"] == actor)
        if table == "vendor_profiles":
            return actor is not None and row["user_id"] == actor
        if table in ADMIN_ONLY or table in ("platform_settings", "payment_events", "audit_log", "device_tokens"):
            return False
        vendor = self.vendor_of(actor) if actor else None
        if table == "orders":
            return row["customer_id"] == actor or bool(vendor and any(v["order_id"] == row["id"] and v["vendor_id"] == vendor["id"] for v in self.rows("vendor_orders")))
        if table == "vendor_orders":
            order = next((o for o in self.rows("orders") if o["id"] == row["order_id"]), None)
            return bool(vendor and row["vendor_id"] == vendor["id"]) or bool(order and order["customer_id"] == actor)
        if table == "order_items":
            vo = next((v for v in self.rows("vendor_orders") if v["id"] == row["vendor_order_id"]), None)
            return bool(vo and self.visible("vendor_orders", vo, actor))
        if table == "order_status_history":
            if row.get("vendor_order_id"):
                vo = next((v for v in self.rows("vendor_orders") if v["id"] == row["vendor_order_id"]), None)
                return bool(vo and self.visible("vendor_orders", vo, actor))
            order = next((o for o in self.rows("orders") if o["id"] == row["order_id"]), None)
            return bool(order and order["customer_id"] == actor)
        if table == "payments":
            return row["customer_id"] == actor
        if table == "refunds":
            pay = next((p for p in self.rows("payments") if p["id"] == row["payment_id"]), None)
            return bool(pay and pay["customer_id"] == actor)
        if table == "vendor_settlements":
            return bool(vendor and row["vendor_id"] == vendor["id"])
        if table == "notifications":
            return row["user_id"] == actor
        return True

    def can_write_row(self, table, row, actor):
        if actor == SERVICE:
            return True
        role = self.role(actor)
        if role == "admin":
            return True
        if table == "products":
            v = self.vendor_of(actor)
            return bool(v and row["vendor_id"] == v["id"] and self.approved_vendor_actor(actor))
        if table == "product_images":
            prod = next((p for p in self.rows("products") if p["id"] == row["product_id"]), None)
            return bool(prod and self.can_write_row("products", prod, actor))
        if table in ("categories", "banners", "orders", "payments", "refunds", "vendor_orders", "order_items", "platform_settings", "commission_rules",
                     "service_categories", "service_bookings", "pickup_dropoff_requests", "support_tickets"):
            return False
        if table == "vendor_services":
            v = self.vendor_of(actor) if actor else None
            return bool(v and row["vendor_id"] == v["id"] and self.approved_vendor_actor(actor))
        if table == "service_booking_images":
            b = next((x for x in self.rows("service_bookings") if x["id"] == row["booking_id"]), None)
            return bool(b and b["customer_id"] == actor and b["status"] == "pending" and row.get("uploaded_by") == actor)
        return True

    def check_write(self, table, op, new, old, actor):
        if actor == SERVICE or self.role(actor) == "admin":
            return
        if table in ("categories", "banners", "platform_settings", "coupons", "commission_rules", "orders", "payments", "refunds", "vendor_orders", "order_items", "audit_log",
                     "service_categories", "service_bookings", "pickup_dropoff_requests", "service_charges", "service_booking_notes", "booking_status_history"):
            raise _pg_error("42501", "row-level security")
        if table == "vendor_services":
            v = self.vendor_of(actor) if actor else None
            if op == "insert" and not (v and self.approved_vendor_actor(actor) and new["vendor_id"] == v["id"]):
                raise _pg_error("42501", "row-level security")
        if table == "support_tickets" and op == "insert" and (new.get("requester_id") != actor or new.get("status") != "open"):
            raise _pg_error("42501", "row-level security")
        if table == "service_booking_images" and op == "insert":
            b = next((x for x in self.rows("service_bookings") if x["id"] == new["booking_id"]), None)
            if not (b and b["customer_id"] == actor and b["status"] == "pending" and new.get("uploaded_by") == actor):
                raise _pg_error("42501", "row-level security")
        if table == "products":
            if op == "insert" and not (self.approved_vendor_actor(actor) and new["vendor_id"] == self.vendor_of(actor)["id"]):
                raise _pg_error("42501", "row-level security")
            for f in PRIVILEGED_PRODUCT_FIELDS:   # guard_product trigger
                default = {"approval_status": "pending", "is_featured": False}.get(f)
                if (op == "insert" and new.get(f) != default) or (op == "update" and new.get(f) != old.get(f)):
                    raise _pg_error("42501", "approval/featured fields are controlled by administrators")
        if table == "product_images" and op == "insert":
            prod = next((p for p in self.rows("products") if p["id"] == new["product_id"]), None)
            if not (prod and self.can_write_row("products", prod, actor)):
                raise _pg_error("42501", "row-level security")
        if table in ("carts", "wishlists") and new["user_id"] != actor:
            raise _pg_error("42501", "row-level security")

    def after_update(self, table, old, new):
        """Python twin of the AFTER UPDATE triggers of migration 20 (the real ones run against PostgreSQL in test_sql_integrity.py)."""
        if table == "products" and old.get("approval_status") != new.get("approval_status") and new["approval_status"] in ("approved", "rejected"):
            vendor = next((v for v in self.rows("vendor_profiles") if v["id"] == new["vendor_id"]), None)
            if vendor:
                rejected = new["approval_status"] == "rejected"
                self.sql._note(vendor["user_id"], "system", "Product rejected" if rejected else "Product approved",
                               f"\"{new['name']}\" was {new['approval_status']}" + (f": {new.get('review_notes')}" if rejected and new.get("review_notes") else " and can now be shown to customers") + ".",
                               "product", new["id"])

    def cascade_delete(self, table, deleted):
        ids = {r["id"] for r in deleted}
        if table == "products":
            for child in ("product_images", "cart_items", "wishlist_items"):
                self.tables[child] = [r for r in self.rows(child) if r["product_id"] not in ids]

    def apply_defaults(self, table, row):
        row.setdefault("id", str(uuid.uuid4()))
        self._tick = getattr(self, "_tick", 0) + 1          # strictly increasing like a real clock (stable ordering in tests)
        row.setdefault("created_at", f"2026-01-01T00:00:00.{self._tick:06d}+00:00")
        row.setdefault("updated_at", self.now())
        if table == "user_addresses":
            row.setdefault("is_default", False)
            row.setdefault("country", "India")
            for k in ("label", "address_line2", "landmark"):
                row.setdefault(k, None)
        if table == "vendor_profiles":
            row["verification_status"] = "pending"  # DB default + guard trigger
            for k in ("description", "address_line2", "contact_email", "service_radius_km", "rejection_reason", "reviewed_at", "reviewed_by", "review_notes"):
                row.setdefault(k, None)
            row.setdefault("operating_hours", {})
            row.setdefault("shop_image_paths", [])
            row.setdefault("service_area_postal_codes", [])
            row.setdefault("pickup_available", False)
        if table == "products":
            row.setdefault("approval_status", "pending"); row.setdefault("is_active", True); row.setdefault("is_featured", False)
            row.setdefault("is_available", True); row.setdefault("stock_quantity", 0); row.setdefault("specifications", {})
            for k in ("description", "brand", "model", "reviewed_by", "reviewed_at", "review_notes"):
                row.setdefault(k, None)
        if table == "product_images":
            row.setdefault("sort_order", 0); row.setdefault("is_primary", False); row.setdefault("alt_text", None)
        if table == "categories":
            row.setdefault("is_active", True); row.setdefault("sort_order", 0)
            for k in ("parent_id", "description", "image_path"):
                row.setdefault(k, None)
        if table in ("orders", "vendor_orders", "payments", "refunds", "vendor_settlements", "audit_log", "payment_events"):
            pass
        if table == "commission_rules":
            row.setdefault("is_active", True); row.setdefault("priority", 0); row.setdefault("effective_until", None); row.setdefault("effective_from", self.now())
            for k in ("vendor_id", "category_id", "service_category_id"):
                row.setdefault(k, None)
        if table == "coupons":
            row.setdefault("is_active", True); row.setdefault("used_count", 0); row.setdefault("min_order_amount", 0); row.setdefault("applies_to", "all")
            for k in ("usage_limit", "per_user_limit", "max_discount_amount", "valid_until", "description", "created_by"):
                row.setdefault(k, None)
            row.setdefault("valid_from", "2020-01-01T00:00:00+00:00")
        if table == "vendor_services":
            row.setdefault("is_active", True); row.setdefault("is_available", True); row.setdefault("slot_minutes", 60); row.setdefault("max_bookings_per_slot", 1)
            for k in ("description", "estimated_duration_minutes", "available_days"):
                row.setdefault(k, None)
        if table == "service_categories":
            row.setdefault("is_active", True); row.setdefault("sort_order", 0)
            for k in ("description", "image_path"):
                row.setdefault(k, None)
        if table == "support_tickets":
            row.setdefault("status", "open"); row.setdefault("ticket_number", f"TKT-{len(self.rows('support_tickets')) + 1:08d}")
            for k in ("assigned_to", "admin_notes", "resolution", "resolved_at", "order_id", "service_booking_id"):
                row.setdefault(k, None)
        if table == "service_booking_images":
            row.setdefault("uploaded_by", None)
        if table == "notifications":
            row.setdefault("push_status", "pending"); row.setdefault("push_attempts", 0); row.setdefault("push_next_at", None); row.setdefault("push_sent_at", None)
            row.setdefault("push_error", None); row.setdefault("read_at", None); row.setdefault("event_key", None); row.setdefault("related_type", None)
            row.setdefault("related_id", None); row.setdefault("announcement_id", None); row.setdefault("is_read", False)
        if table == "device_tokens":
            row.setdefault("is_active", True); row.setdefault("device_label", None); row.setdefault("app_version", None); row.setdefault("last_error", None)
        if table == "banners":
            row.setdefault("is_active", True); row.setdefault("sort_order", 0)
            for k in ("subtitle", "action_value", "starts_at", "ends_at", "created_by"):
                row.setdefault(k, None)
        return row

    def check_unique(self, table, row, others):
        if table == "vendor_profiles" and any(o["user_id"] == row["user_id"] for o in others):
            raise _pg_error("23505", "duplicate key")
        if table == "user_addresses" and row.get("is_default") and any(o["user_id"] == row["user_id"] and o.get("is_default") for o in others):
            raise _pg_error("23505", "one default per user")
        if table == "profiles" and row.get("phone") and any(o.get("phone") == row["phone"] for o in others):
            raise _pg_error("23505", "phone taken")
        if table == "categories" and any(o["slug"] == row["slug"] for o in others):
            raise _pg_error("23505", "slug taken")
        if table == "product_images":
            if any(o["product_id"] == row["product_id"] and o["storage_path"] == row["storage_path"] for o in others):
                raise _pg_error("23505", "duplicate image")
            if row.get("is_primary") and any(o["product_id"] == row["product_id"] and o.get("is_primary") for o in others):
                raise _pg_error("23505", "one primary image")
        if table in ("cart_items", "wishlist_items"):
            parent = "cart_id" if table == "cart_items" else "wishlist_id"
            if any(o[parent] == row[parent] and o["product_id"] == row["product_id"] for o in others):
                raise _pg_error("23505", "duplicate item")
        if table == "vendor_services" and any(o["vendor_id"] == row["vendor_id"] and o["service_category_id"] == row["service_category_id"] and o["name"] == row["name"] for o in others):
            raise _pg_error("23505", "service exists")
        if table == "service_categories" and any(o["slug"] == row["slug"] for o in others):
            raise _pg_error("23505", "slug taken")
        if table in ("carts", "wishlists") and any(o["user_id"] == row["user_id"] for o in others):
            raise _pg_error("23505", "one per user")

    # ---- seeding helpers
    def add_profile(self, role="customer", status="active", phone=None, user_id=None, **extra):
        uid = user_id or str(uuid.uuid4())
        self.rows("profiles").append({
            "id": uid, "full_name": "Test User", "email": f"{uid[:8]}@example.com", "phone": phone, "role": role,
            "status": status, "avatar_path": None, "created_at": self.now(), "updated_at": self.now(), **extra})
        return uid

    def add_vendor(self, user_id, status="pending", **extra):
        row = self.apply_defaults("vendor_profiles", {
            "user_id": user_id, "business_name": "Shop", "business_types": ["bicycle_shop"], "address_line1": "1 Rd",
            "city": "Pune", "state": "MH", "postal_code": "411001", "contact_phone": "+919800000001", **extra})
        row["verification_status"] = status
        self.rows("vendor_profiles").append(row)
        return row

    def add_approved_vendor(self, name="Shop"):
        uid = self.add_profile(role="vendor")
        return uid, self.add_vendor(uid, "approved", business_name=name)

    def add_category(self, kind="new_cycle", name=None, **extra):
        name = name or kind.replace("_", " ").title()
        row = self.apply_defaults("categories", {"kind": kind, "name": name, "slug": name.lower().replace(" ", "-") + str(uuid.uuid4())[:4], **extra})
        self.rows("categories").append(row)
        return row

    def add_product(self, vendor_id, category, **extra):
        row = self.apply_defaults("products", {
            "vendor_id": vendor_id, "category_id": category["id"], "product_type": category["kind"], "name": "Road Bike",
            "condition": "used" if category["kind"] == "used_cycle" else "new", "price": 1000.0, "stock_quantity": 5,
            "approval_status": "approved", **extra})
        self.rows("products").append(row)
        return row

    def add_image(self, product_id, path=None, **extra):
        row = self.apply_defaults("product_images", {"product_id": product_id, "storage_path": path or f"u/{uuid.uuid4()}.jpg", **extra})
        self.rows("product_images").append(row)
        return row


# ---------------- fixtures ----------------
@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", SUPABASE_URL)
    monkeypatch.setenv("SUPABASE_ANON_KEY", "anon-placeholder")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-placeholder")
    monkeypatch.delenv("SUPABASE_JWT_SECRET", raising=False)
    get_settings.cache_clear(); sb.get_admin_client.cache_clear(); sb.get_anon_client.cache_clear()
    yield
    get_settings.cache_clear(); sb.get_admin_client.cache_clear(); sb.get_anon_client.cache_clear()


@pytest.fixture(autouse=True)
def fake_jwks(monkeypatch):
    class FakeJWKS:
        def get_signing_key_from_jwt(self, _token):
            return SimpleNamespace(key=_PRIVATE.public_key())

    monkeypatch.setattr(security, "_jwks_client", lambda *a, **k: FakeJWKS())


@pytest.fixture
def db(monkeypatch):
    fake = FakeDB()

    def user_factory(token):
        fake.tokens_used.append(token)
        sub = jwt.decode(token, options={"verify_signature": False})["sub"]
        return FakeClient(fake, sub)

    monkeypatch.setattr(deps, "create_user_db_client", user_factory)
    monkeypatch.setattr(deps, "create_anon_db_client", lambda: FakeClient(fake, None))
    monkeypatch.setattr(deps, "create_admin_db_client", lambda: FakeClient(fake, SERVICE))
    return fake


@pytest.fixture
def client(db):
    return TestClient(app, raise_server_exceptions=False)


@pytest.fixture
def make_token():
    def _make(sub=None, *, exp_in=3600, iss=ISSUER, aud="authenticated", role="authenticated", alg="RS256",
              key=None, extra=None, drop=()):
        now = int(time.time())
        claims = {"sub": sub or str(uuid.uuid4()), "aud": aud, "iss": iss, "role": role, "iat": now, "exp": now + exp_in,
                  "email": "u@example.com", "phone": "", "session_id": "sess-1", "aal": "aal1", **(extra or {})}
        for k in drop:
            claims.pop(k, None)
        if alg == "none":
            return jwt.encode(claims, None, algorithm="none")
        return jwt.encode(claims, key or _PRIVATE, algorithm=alg, headers={"kid": "k1"})
    return _make


@pytest.fixture
def other_private_key():
    return _OTHER_PRIVATE


@pytest.fixture
def auth(make_token):
    """auth(user_id, **token_overrides) -> headers"""
    return lambda uid, **kw: {"Authorization": f"Bearer {make_token(uid, **kw)}"}


# ---------------------------------------------------------------- Step 5: payment provider test double + commerce world
import hashlib  # noqa: E402
import hmac  # noqa: E402
import json  # noqa: E402
from decimal import Decimal  # noqa: E402

from app.integrations.payments.base import (  # noqa: E402
    InvalidWebhookSignature,
    PaymentInitiation,
    PaymentProviderError,
    ProviderPaymentState,
    ProviderRefund,
    WebhookEvent,
)

WEBHOOK_SECRET = "whsec_test"


class FakeProvider:
    """TEST DOUBLE ONLY (not a real gateway). Implements the PaymentProvider contract with genuine HMAC signature verification."""

    name = "testpay"

    def __init__(self, configured=True):
        self.configured, self.created, self.refunds, self.fail_create, self.state = configured, [], [], False, "pending"
        self.refund_status = "processed"

    def is_configured(self):
        return self.configured

    def create_payment(self, *, reference, amount, currency, customer_id, description):
        if self.fail_create:
            raise PaymentProviderError()
        self.created.append(reference)
        return PaymentInitiation(provider_order_id=f"po_{reference[:8]}", client_payload={"order_id": f"po_{reference[:8]}", "amount": str(amount), "currency": currency})

    def client_payload(self, *, provider_order_id, amount, currency):
        return {"order_id": provider_order_id, "amount": str(amount), "currency": currency}

    def parse_webhook(self, headers, body):
        from app.integrations.payments.base import verify_hmac_sha256
        if not verify_hmac_sha256(WEBHOOK_SECRET, body, headers.get("x-test-signature", "")):
            raise InvalidWebhookSignature()
        data = json.loads(body)
        return [WebhookEvent(event_id=e["id"], event_type=e["type"], provider_order_id=e.get("order"), provider_payment_id=e.get("payment"),
                             provider_refund_id=e.get("refund"), amount=Decimal(e["amount"]) if e.get("amount") is not None else None, currency=e.get("currency"),
                             failure_reason=e.get("reason")) for e in data["events"]]

    def refund(self, *, provider_payment_id, amount, currency, reference):
        self.refunds.append((provider_payment_id, amount, reference))
        return ProviderRefund(provider_refund_id=f"rf_{reference[:8]}", status=self.refund_status)

    def fetch_payment(self, *, provider_order_id):
        return ProviderPaymentState(status=self.state, provider_payment_id="pay_x", amount=Decimal("1000"), currency="INR")


def sign(body: bytes) -> str:
    return hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()


@pytest.fixture
def provider():
    return FakeProvider()


@pytest.fixture
def world(db, provider, auth, client):
    """Two approved vendors, products, a customer with a saved address, COD enabled and a global 10% commission rule."""
    from app.core.dependencies import get_provider
    app.dependency_overrides[get_provider] = lambda: provider
    ua, va = db.add_approved_vendor("Alpha")
    ub, vb = db.add_approved_vendor("Beta")
    cat, parts = db.add_category("new_cycle", "Cycles"), db.add_category("spare_part", "Parts")
    bike = db.add_product(va["id"], cat, name="Bike", price=1000.0, stock_quantity=5, brand="Hero")
    pads = db.add_product(vb["id"], parts, name="Pads", price=250.5, stock_quantity=4)
    cust = db.add_profile()
    other = db.add_profile()
    admin = db.add_profile(role="admin")
    addr = db.apply_defaults("user_addresses", {"user_id": cust, "recipient_name": "Asha", "phone": "+919800000001", "address_line1": "1 MG Rd", "city": "Pune",
                                               "state": "MH", "postal_code": "411001", "address_type": "both"})
    db.rows("user_addresses").append(addr)
    db.rows("platform_settings").append({"key": "payments.cod_enabled", "value": True})
    db.rows("commission_rules").append(db.apply_defaults("commission_rules", {"name": "Global", "applies_to": "product", "commission_type": "percentage", "commission_value": 10}))
    cart = db.apply_defaults("carts", {"user_id": cust}); db.rows("carts").append(cart)

    class W:
        pass

    w = W()
    w.db, w.provider, w.cust, w.other, w.admin, w.addr, w.cart = db, provider, cust, other, admin, addr, cart
    w.va, w.vb, w.ua, w.ub, w.bike, w.pads, w.cat, w.parts = va, vb, ua, ub, bike, pads, cat, parts
    w.h, w.ha, w.hva, w.hvb, w.hother = auth(cust), auth(admin), auth(ua), auth(ub), auth(other)
    w.n = 0

    def add_to_cart(product, qty=1):
        row = db.apply_defaults("cart_items", {"cart_id": cart["id"], "product_id": product["id"], "quantity": qty, "price_when_added": product["price"]})
        db.rows("cart_items").append(row)
        return row

    def checkout(body=None, key=None, headers=None):
        w.n += 1
        payload = {"delivery_address_id": addr["id"], "payment_method": "cod", **(body or {})}
        return client.post("/api/v1/checkout", json=payload, headers={**(headers or w.h), "Idempotency-Key": key or f"key-{w.n:08d}"})

    def webhook(*events, sig=None):
        raw = json.dumps({"events": list(events)}).encode()
        return client.post("/api/v1/payments/webhook", content=raw, headers={"x-test-signature": sig if sig is not None else sign(raw), "content-type": "application/json"})

    w.add, w.checkout, w.webhook = add_to_cart, checkout, webhook
    yield w
    app.dependency_overrides.pop(get_provider, None)


# ---------------------------------------------------------------- Step 6: servicing world
@pytest.fixture
def swd(db, auth, client, monkeypatch):
    """An approved provider with pickup, open every day 09:00-18:00, a 60-minute 'Full service' (capacity 1), a customer with saved addresses, an admin."""
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo

    import app.services._booking_builder as builder
    import app.services.booking_service as booking_service

    storage = {"uploaded": set(), "deleted": [], "type": "image/jpeg", "size": 1000}

    def info(token, bucket, path):
        return (storage["type"], storage["size"]) if path in storage["uploaded"] else None

    monkeypatch.setattr(booking_service, "private_object_info", info)
    monkeypatch.setattr(booking_service, "delete_storage_object", lambda t, b, p: storage["deleted"].append(p))
    monkeypatch.setattr(builder, "create_signed_url", lambda token, bucket, path, expires_in=3600: f"https://signed.example/{bucket}/{path}?t=1")

    hours = {d: {"open": "09:00", "close": "18:00"} for d in ("mon", "tue", "wed", "thu", "fri", "sat", "sun")}
    ua, va = db.add_approved_vendor("Alpha Cycles")
    va.update(pickup_available=True, operating_hours=hours, service_area_postal_codes=["411001", "411002"], city="Pune", state="MH")
    ub, vb = db.add_approved_vendor("Beta Bikes")
    vb.update(pickup_available=False, operating_hours=hours)
    cat = db.apply_defaults("service_categories", {"name": "General Servicing", "slug": "general-servicing", "sort_order": 1}); db.rows("service_categories").append(cat)
    cat2 = db.apply_defaults("service_categories", {"name": "Puncture Repair", "slug": "puncture-repair", "sort_order": 2}); db.rows("service_categories").append(cat2)

    def mk_service(vendor, category, name="Full service", price=499.0, **kw):
        row = db.apply_defaults("vendor_services", {"vendor_id": vendor["id"], "service_category_id": category["id"], "name": name, "price": price,
                                                  "estimated_duration_minutes": 120, **kw})
        db.rows("vendor_services").append(row)
        return row

    svc, svc_b = mk_service(va, cat), mk_service(vb, cat, "Basic")
    cust, other, admin = db.add_profile(), db.add_profile(), db.add_profile(role="admin")

    def address(uid, kind="both", postal="411001"):
        a = db.apply_defaults("user_addresses", {"user_id": uid, "recipient_name": "Asha", "phone": "+919800000001", "address_line1": "1 MG Rd", "city": "Pune",
                                                "state": "MH", "postal_code": postal, "address_type": kind})
        db.rows("user_addresses").append(a)
        return a

    class W:
        pass

    w = W()
    w.db, w.storage, w.ua, w.ub, w.va, w.vb, w.cat, w.cat2, w.svc, w.svc_b = db, storage, ua, ub, va, vb, cat, cat2, svc, svc_b
    w.cust, w.other, w.admin, w.address, w.mk_service = cust, other, admin, address, mk_service
    w.addr = address(cust)
    w.h, w.hother, w.ha, w.hva, w.hvb = auth(cust), auth(other), auth(admin), auth(ua), auth(ub)
    today = datetime.now(ZoneInfo("Asia/Kolkata")).date()
    w.day = lambda n=3: (today + timedelta(days=n)).isoformat()
    w.n = 0

    def book(service=None, headers=None, **over):
        body = {"service_id": (service or svc)["id"], "issue_description": "Brakes squeal and the chain skips", "preferred_date": w.day(3), "slot_start": "10:00", **over}
        return client.post("/api/v1/service-bookings", json=body, headers=headers or w.h)

    w.book = book
    w.pickup_body = lambda **kw: {"needs_pickup_dropoff": True, "pickup_address_id": w.addr["id"], **kw}
    w.setting = lambda k, v: db.rows("platform_settings").append({"key": k, "value": v})
    return w
