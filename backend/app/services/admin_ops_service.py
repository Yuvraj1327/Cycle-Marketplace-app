"""Step 10 admin operations: coupons, announcements/notifications, reports, audit trail, fulfilment overview.
Reads/writes run with the admin's OWN token (RLS `is_admin()`); service-role access is limited to the audit log, the atomic announcement
function and read-only aggregates - always after `require_admin` has verified the caller."""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from uuid import UUID
from zoneinfo import ZoneInfo

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict, unprocessable
from app.core.money import q2
from app.core.search import sanitize_term
from app.repositories.admin_ops_repository import (
    AnnouncementRepository,
    AuditReader,
    CouponAdminRepository,
    DirectoryRepository,
    OpsGateway,
    VendorOrderAdminRepository,
)
from app.repositories.commerce_config_repository import AuditRepository
from app.schemas.admin_ops import AnnouncementCreate, CouponCreate, CouponUpdate, ReportKind
from app.services import _catalog
from app.services._pricing import _parse_ts
from app.services._updates import changes

PLATFORM_TZ = ZoneInfo("Asia/Kolkata")
MAX_REPORT_DAYS = 366


def local_today() -> date:
    return datetime.now(PLATFORM_TZ).date()


# ============================================================ coupons
def coupon_state(c: dict, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    start, end = _parse_ts(c.get("valid_from")), _parse_ts(c.get("valid_until"))
    if not c["is_active"]:
        return "inactive"
    if start and start > now:
        return "scheduled"
    if end and end <= now:
        return "expired"
    if c.get("usage_limit") is not None and c["used_count"] >= c["usage_limit"]:
        return "exhausted"
    return "active"


def _coupon_out(c: dict) -> dict:
    return {**c, "state": coupon_state(c)}


class CouponAdminService:
    """Coupons are redeemed (and `used_count` increased) only by the checkout SQL function. There is no per-redemption table: usage is the counter
    plus the orders that carry the coupon code."""

    def __init__(self, db, admin_db):
        self.coupons = CouponAdminRepository(db)
        self.audit = AuditRepository(admin_db)

    def list(self, *, q: str | None, is_active: bool | None, page: int, limit: int) -> dict:
        term = sanitize_term(q or "", 50) or None
        if q and not term:
            return _catalog.page([], 0, page, limit)
        rows, total = self.coupons.search(q=term, is_active=is_active, page=page, limit=limit)
        return _catalog.page([_coupon_out(r) for r in rows], total, page, limit)

    def get(self, coupon_id: UUID) -> dict:
        row = self.coupons.find(str(coupon_id))
        if row is None:
            raise NotFoundError("Coupon not found.")
        return _coupon_out(row)

    def create(self, admin: CurrentUser, body: CouponCreate) -> dict:
        if self.coupons.find_by_code(body.code):
            raise conflict("coupon_code_taken", "A coupon with this code already exists.")
        values = body.model_dump(mode="json", exclude_none=True)
        values["code"] = body.code.upper()
        row = self.coupons.create({**values, "created_by": admin.id})
        self.audit.record(admin.id, "coupon_created", "coupon", row["id"], {"code": row["code"], "discount_type": row["discount_type"], "discount_value": float(q2(row["discount_value"]))})
        return _coupon_out(row)

    def update(self, admin: CurrentUser, coupon_id: UUID, body: CouponUpdate) -> dict:
        current = self.coupons.find(str(coupon_id))
        if current is None:
            raise NotFoundError("Coupon not found.")
        values = changes(body, nullable={"description", "max_discount_amount", "valid_until", "usage_limit", "per_user_limit"})
        merged = {**current, **values}
        if "code" in values:
            values["code"] = merged["code"] = body.code.upper()                       # type: ignore[union-attr]
            if values["code"] != current["code"].upper():
                if current["used_count"] > 0:
                    raise conflict("coupon_code_locked", "This coupon has already been used, so its code can no longer be changed. Deactivate it and create a new one.")
                clash = self.coupons.find_by_code(values["code"])
                if clash and clash["id"] != current["id"]:
                    raise conflict("coupon_code_taken", "A coupon with this code already exists.")
            else:
                values.pop("code")
        self._check_merged(merged)
        row = self.coupons.update(str(coupon_id), values)
        self.audit.record(admin.id, "coupon_updated", "coupon", str(coupon_id), values)
        return _coupon_out(row)

    @staticmethod
    def _check_merged(c: dict) -> None:
        value = Decimal(str(c["discount_value"]))
        if c["discount_type"] == "percentage" and value > 100:
            raise unprocessable("invalid_coupon", "A percentage discount cannot exceed 100.")
        if c["discount_type"] == "fixed" and c.get("max_discount_amount") is not None:
            raise unprocessable("invalid_coupon", "A maximum discount only applies to percentage coupons.")
        start, end = _parse_ts(c.get("valid_from")), _parse_ts(c.get("valid_until"))
        if start and end and end <= start:
            raise unprocessable("invalid_coupon", "The coupon must end after it starts.")
        if c.get("usage_limit") is not None and c["usage_limit"] < c["used_count"]:
            raise unprocessable("invalid_coupon", f"The usage limit cannot be lower than the {c['used_count']} redemption(s) already made.")


# ============================================================ announcements & notifications
class CommunicationAdminService:
    """Announcements fan out into ordinary in-app `notifications` rows. Nothing here sends a push message."""

    def __init__(self, db, admin_db):
        self.rows = AnnouncementRepository(db)
        self.gateway = OpsGateway(admin_db)
        self.people = DirectoryRepository(db)
        self.audit = AuditRepository(admin_db)

    def send(self, admin: CurrentUser, body: AnnouncementCreate) -> dict:
        ids = None
        if body.audience.value == "specific":
            ids = sorted({str(u) for u in body.user_ids or []})
            known = self.people.profiles(ids, "id,role,status")
            bad = [i for i in ids if i not in known or known[i]["role"] not in ("customer", "vendor")]
            if bad:
                raise unprocessable("invalid_recipient", "Some recipients are not customer or vendor accounts.", details=[{"user_id": i} for i in bad])
        result = self.gateway.send_announcement(title=body.title, message=body.message, type=body.type.value, audience=body.audience.value, user_ids=ids, admin_id=admin.id)
        self.audit.record(admin.id, "announcement_sent", "announcement", result["id"],
                          {"title": body.title, "type": body.type.value, "audience": body.audience.value, "recipients": result["recipient_count"]})
        return self.get(UUID(result["id"]))

    def get(self, announcement_id: UUID) -> dict:
        row = self.rows.find(str(announcement_id))
        if row is None:
            raise NotFoundError("Announcement not found.")
        return self._views([row])[0]

    def list(self, *, type: str | None, audience: str | None, page: int, limit: int) -> dict:
        rows, total = self.rows.search(type=type, audience=audience, page=page, limit=limit)
        return _catalog.page(self._views(rows), total, page, limit)

    def list_notifications(self, *, type: str | None, user_id: UUID | None, announcement_id: UUID | None, q: str | None, date_from: date | None,
                           date_to: date | None, page: int, limit: int) -> dict:
        term = sanitize_term(q or "", 60, allow_at=True) or None
        if q and not term:
            return _catalog.page([], 0, page, limit)
        user_ids = self.people.customer_ids_matching(term) if term else None
        rows, total = self.rows.notifications(type=type, user_id=str(user_id) if user_id else None, announcement_id=str(announcement_id) if announcement_id else None,
                                              user_ids=user_ids, date_from=date_from, date_to=date_to, page=page, limit=limit)
        people = self.people.profiles([r["user_id"] for r in rows])
        items = [{"id": r["id"], "user_id": r["user_id"], "recipient_name": (people.get(r["user_id"]) or {}).get("full_name"), "recipient_role": (people.get(r["user_id"]) or {}).get("role"),
                  "type": r["type"], "title": r["title"], "message": r["message"], "related_type": r.get("related_type"), "related_id": r.get("related_id"),
                  "is_read": r["is_read"], "announcement_id": r.get("announcement_id"), "created_at": r["created_at"], "channel": "in_app",
                  "push_status": r.get("push_status") or "skipped", "push_error": r.get("push_error")} for r in rows]
        return _catalog.page(items, total, page, limit)

    def _views(self, rows: list[dict]) -> list[dict]:
        stats = self.gateway.announcement_stats([r["id"] for r in rows])
        names = {k: v.get("full_name") for k, v in self.people.profiles([r["created_by"] for r in rows if r.get("created_by")], "id,full_name").items()}
        return [{**{k: r[k] for k in ("id", "title", "message", "type", "audience", "recipient_count", "created_by", "created_at")},
                 "delivered": (stats.get(r["id"]) or {}).get("delivered", 0), "read": (stats.get(r["id"]) or {}).get("read", 0),
                 "push_sent": (stats.get(r["id"]) or {}).get("push_sent", 0), "push_failed": (stats.get(r["id"]) or {}).get("push_failed", 0),
                 "push_pending": (stats.get(r["id"]) or {}).get("push_pending", 0),
                 "created_by_name": names.get(r.get("created_by")), "channel": "in_app"} for r in rows]


# ============================================================ reports
class ReportAdminService:
    def __init__(self, admin_db):
        self.gateway = OpsGateway(admin_db)

    def report(self, kind: ReportKind, date_from: date | None, date_to: date | None) -> dict:
        end = date_to or local_today()
        start = date_from or end - timedelta(days=29)
        if start > end:
            raise unprocessable("invalid_range", "`from` must not be after `to`.")
        if (end - start).days + 1 > MAX_REPORT_DAYS:
            raise unprocessable("range_too_long", f"Choose a period of at most {MAX_REPORT_DAYS} days.")
        data = self.gateway.report(kind.value, start, end)
        return {"kind": kind.value, "period_from": start.isoformat(), "period_to": end.isoformat(), "timezone": "Asia/Kolkata", "data": data}


# ============================================================ audit trail
class AuditAdminService:
    def __init__(self, db):
        self.rows = AuditReader(db)
        self.people = DirectoryRepository(db)

    def list(self, *, entity_type: str | None, entity_id: UUID | None, action: str | None, actor_id: UUID | None, page: int, limit: int) -> dict:
        rows, total = self.rows.search(entity_type=entity_type, entity_id=str(entity_id) if entity_id else None, action=action, actor_id=str(actor_id) if actor_id else None, page=page, limit=limit)
        names = self.people.profiles([r["actor_id"] for r in rows if r.get("actor_id")], "id,full_name")
        items = [{**{k: r.get(k) for k in ("id", "actor_id", "actor_role", "action", "entity_type", "entity_id", "details", "created_at")},
                  "actor_name": (names.get(r.get("actor_id")) or {}).get("full_name"), "details": r.get("details") or {}} for r in rows]
        return _catalog.page(items, total, page, limit)


# ============================================================ fulfilment overview
class FulfilmentAdminService:
    """Read-only flat list of vendor orders: who must deliver what to whom, and where each one stands."""

    def __init__(self, db):
        self.rows = VendorOrderAdminRepository(db)
        self.people = DirectoryRepository(db)

    def list(self, *, status: str | None, vendor_id: UUID | None, q: str | None, date_from: date | None, date_to: date | None, page: int, limit: int) -> dict:
        term = sanitize_term(q or "", 40, allow_at=True) or None
        if q and not term:
            return _catalog.page([], 0, page, limit)
        order_ids = vendor_ids = None
        if term:
            number_ids = self.people.order_ids_matching_number(term)
            customers = self.people.customer_ids_matching(term)
            by_customer = [r["id"] for r in self.rows._run(self.rows.client.table("orders").select("id").in_("customer_id", customers)).data] if customers else []
            order_ids = sorted(set(number_ids) | set(by_customer))
            vendor_ids = self.people.vendor_ids_matching(term)
            # a vendor-order number or order/customer match OR a vendor-name match: run both and merge
            a, ta = self.rows.search(status=status, vendor_id=str(vendor_id) if vendor_id else None, order_ids=order_ids, vendor_ids=None, date_from=date_from, date_to=date_to, page=1, limit=500)
            b, _ = self.rows.search(status=status, vendor_id=str(vendor_id) if vendor_id else None, order_ids=None, vendor_ids=vendor_ids, date_from=date_from, date_to=date_to, page=1, limit=500)
            seen: dict[str, dict] = {}
            for r in [*a, *b]:
                seen[r["id"]] = r
            merged = sorted(seen.values(), key=lambda r: (str(r["created_at"]), r["id"]), reverse=True)
            total = len(merged)
            offset = (page - 1) * limit
            rows = merged[offset: offset + limit]
        else:
            rows, total = self.rows.search(status=status, vendor_id=str(vendor_id) if vendor_id else None, order_ids=None, vendor_ids=None, date_from=date_from, date_to=date_to, page=page, limit=limit)
        return _catalog.page(self._views(rows), total, page, limit)

    def _views(self, rows: list[dict]) -> list[dict]:
        orders = self.rows.orders([r["order_id"] for r in rows])
        people = self.people.profiles([o["customer_id"] for o in orders.values()], "id,full_name")
        counts = self.rows.item_counts([r["id"] for r in rows])
        vendors = self.people.vendor_names([r["vendor_id"] for r in rows])
        out = []
        for r in rows:
            o = orders.get(r["order_id"]) or {}
            addr = o.get("delivery_address") or {}
            out.append({"id": r["id"], "vendor_order_number": r["vendor_order_number"], "order_id": r["order_id"], "order_number": o.get("order_number"), "vendor_id": r["vendor_id"],
                        "vendor_name": r.get("vendor_name") or vendors.get(r["vendor_id"]), "customer_id": o.get("customer_id"),
                        "customer_name": (people.get(o.get("customer_id")) or {}).get("full_name"), "status": r["status"], "order_status": o.get("status"),
                        "payment_method": o.get("payment_method"), "payment_status": o.get("payment_status"), "delivery_city": addr.get("city"),
                        "delivery_postal_code": addr.get("postal_code"), "item_count": counts.get(r["id"], 0), "subtotal": r["subtotal"], "total_amount": r["total_amount"],
                        "commission_amount": r.get("commission_amount"), "accepted_at": r.get("accepted_at"), "delivered_at": r.get("delivered_at"), "created_at": r["created_at"]})
        return out
