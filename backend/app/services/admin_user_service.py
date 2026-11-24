"""Customer and vendor administration. Authorisation: route-level `require_admin` first, then the admin's own token (RLS is_admin + guard triggers).
Every state change is a compare-and-set, is written to the audit log with the admin's id, and never deletes anything."""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from uuid import UUID
from zoneinfo import ZoneInfo

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict, unprocessable
from app.core.search import sanitize_term
from app.integrations.supabase import public_storage_url
from app.repositories.admin_user_repository import AdminGateway, AdminNotifier, AdminProfileRepository, AdminVendorRepository
from app.repositories.commerce_config_repository import AuditRepository
from app.services import _catalog

IST = ZoneInfo("Asia/Kolkata")
VENDOR_FLOW = {   # action -> (allowed current states, new state)
    "approve": (["pending", "rejected"], "approved"),
    "reject": (["pending"], "rejected"),
    "suspend": (["approved"], "suspended"),
    "reinstate": (["suspended"], "approved"),
}


def _counts_map(d: dict, key: str) -> int | None:
    return None if d is None else int(d.get(key, 0))


class AdminUserService:
    def __init__(self, db, admin_db):
        self.profiles = AdminProfileRepository(db)
        self.vendors = AdminVendorRepository(db)
        self.gateway = AdminGateway(admin_db)
        self.audit = AuditRepository(admin_db)
        self.notifier = AdminNotifier(admin_db)

    # ---------------------------------------------------------------- customers
    def list_customers(self, *, q, status, sort, page, limit) -> dict:
        rows, total = self.profiles.search(role="customer", q=sanitize_term(q, allow_at=True) or None if q else None, status=status, sort=sort, page=page, limit=limit)
        counts = self.gateway.counts("customer", [r["id"] for r in rows])
        return _catalog.page([self._customer_item(r, counts.get(r["id"])) for r in rows], total, page, limit)

    def get_customer(self, customer_id: UUID) -> dict:
        row = self._customer(customer_id)
        counts = self.gateway.counts("customer", [row["id"]]).get(row["id"])
        return {**self._customer_item(row, counts), "updated_at": row["updated_at"], "addresses": self.profiles.addresses(row["id"]),
                "activity": self._activity("customer", row["id"])}

    def set_customer_status(self, admin: CurrentUser, customer_id: UUID, status: str, reason: str | None) -> dict:
        row = self._customer(customer_id)
        self._check_status_change(row["status"], status, reason)
        updated = self.profiles.set_status(row["id"], "customer", status)
        if updated is None:
            raise NotFoundError("Customer not found.")
        self.audit.record(admin.id, f"customer_{status}", "customer", row["id"], {"from": row["status"], "to": status, "reason": reason})
        return self.get_customer(customer_id)

    # ---------------------------------------------------------------- vendors
    def list_vendors(self, *, q, business_type, verification_status, account_status, sort, page, limit) -> dict:
        term = sanitize_term(q, allow_at=True) or None if q else None
        include = exclude = None
        if account_status == "active":
            exclude = self.profiles.ids_not_status(role="vendor", status="active")
        elif account_status:
            include = self.profiles.ids_matching(role="vendor", status=account_status)
        owners_for_q = self.profiles.ids_matching(role="vendor", q=term, limit=200) if term else []
        rows, total = self.vendors.search(q=term, owner_ids_for_q=owners_for_q, business_type=business_type, verification_status=verification_status,
                                          include_users=include, exclude_users=exclude, sort=sort, page=page, limit=limit)
        owners = {p["id"]: p for p in self.profiles.many([r["user_id"] for r in rows])}
        counts = self.gateway.counts("vendor", [r["id"] for r in rows])
        return _catalog.page([self._vendor_item(r, owners.get(r["user_id"]), counts.get(r["id"])) for r in rows], total, page, limit)

    def get_vendor(self, vendor_id: UUID) -> dict:
        row = self._vendor(vendor_id)
        owner = next(iter(self.profiles.many([row["user_id"]])), None)
        counts = self.gateway.counts("vendor", [row["id"]]).get(row["id"])
        paths = list(row.get("shop_image_paths") or [])
        return {**self._vendor_item(row, owner, counts), "owner_phone": (owner or {}).get("phone"), "description": row.get("description"),
                "address_line1": row["address_line1"], "address_line2": row.get("address_line2"), "postal_code": row["postal_code"],
                "operating_hours": row.get("operating_hours") or {}, "shop_image_paths": paths,
                "shop_image_urls": [public_storage_url("shop-images", p) for p in paths], "service_area_postal_codes": row.get("service_area_postal_codes") or [],
                "service_radius_km": row.get("service_radius_km"), "pickup_available": bool(row.get("pickup_available")),
                "rejection_reason": row.get("rejection_reason"), "review_notes": row.get("review_notes"), "reviewed_by": row.get("reviewed_by"),
                "reviewed_at": row.get("reviewed_at"), "updated_at": row["updated_at"], "activity": self._activity("vendor", row["id"])}

    def decide(self, admin: CurrentUser, vendor_id: UUID, action: str, *, reason: str | None = None, note: str | None = None) -> dict:
        row = self._vendor(vendor_id)
        expected, target = VENDOR_FLOW[action]
        now = datetime.now(timezone.utc).isoformat()
        values = {"verification_status": target, "reviewed_by": admin.id, "reviewed_at": now}
        if action == "reject":
            values.update(rejection_reason=reason, review_notes=reason)
        elif action == "suspend":
            values.update(rejection_reason=reason, review_notes=reason)       # vendors see the reason in their status screen
        else:
            values.update(rejection_reason=None, review_notes=note)
        if row["verification_status"] == target:
            raise conflict(f"already_{target}", f"This vendor is already {target}.")
        updated = self.vendors.transition(row["id"], expected=expected, values=values)
        if updated is None:                                                     # lost a race, or the transition is not allowed from here
            current = self._vendor(vendor_id)["verification_status"]
            if current == target:
                raise conflict(f"already_{target}", f"This vendor is already {target}.")
            raise conflict("invalid_transition", f"A vendor that is {current} cannot be {self._past(action)}.")
        self.audit.record(admin.id, f"vendor_{target}", "vendor", row["id"], {"from": row["verification_status"], "to": target, "reason": reason, "note": note})
        self._tell_vendor(row, action, reason)
        return self.get_vendor(vendor_id)

    def set_vendor_account_status(self, admin: CurrentUser, vendor_id: UUID, status: str, reason: str | None) -> dict:
        row = self._vendor(vendor_id)
        owner = next(iter(self.profiles.many([row["user_id"]])), None)
        if owner is None:
            raise NotFoundError("Vendor account not found.")
        self._check_status_change(owner["status"], status, reason)
        if self.profiles.set_status(owner["id"], "vendor", status) is None:
            raise NotFoundError("Vendor account not found.")
        self.audit.record(admin.id, f"vendor_account_{status}", "vendor", row["id"], {"from": owner["status"], "to": status, "reason": reason})
        return self.get_vendor(vendor_id)

    # ---------------------------------------------------------------- dashboard
    def dashboard(self, date_from: date | None, date_to: date | None) -> dict:
        today = datetime.now(IST).date()
        end = date_to or today
        start = date_from or end - timedelta(days=29)
        if start > end:
            raise unprocessable("invalid_range", "`from` must not be after `to`.")
        if (end - start).days > 365:
            raise unprocessable("range_too_large", "Choose a period of at most 366 days.")
        return self.gateway.dashboard(start, end)

    # ---------------------------------------------------------------- internals
    @staticmethod
    def _past(action: str) -> str:
        return {"approve": "approved", "reject": "rejected", "suspend": "suspended", "reinstate": "reinstated"}[action]

    @staticmethod
    def _check_status_change(current: str, status: str, reason: str | None) -> None:
        if status == current:
            raise conflict("no_change", f"The account is already {current}.")
        if status != "active" and len((reason or "").strip()) < 3:
            raise unprocessable("reason_required", "Give a reason when deactivating or restricting an account.")

    def _customer(self, customer_id: UUID) -> dict:
        row = self.profiles.find(str(customer_id), "customer")
        if row is None:
            raise NotFoundError("Customer not found.")
        return row

    def _vendor(self, vendor_id: UUID) -> dict:
        row = self.vendors.find(str(vendor_id))
        if row is None:
            raise NotFoundError("Vendor not found.")
        return row

    def _activity(self, entity: str, entity_id: str) -> list[dict]:
        return [{"at": a["created_at"], "action": a["action"], "actor_id": a.get("actor_id"), "details": a.get("details") or {}}
                for a in reversed(self.audit.for_entity(entity, entity_id))]

    @staticmethod
    def _customer_item(r: dict, counts: dict | None) -> dict:
        return {"id": r["id"], "full_name": r.get("full_name") or None, "email": r.get("email"), "phone": r.get("phone"), "status": r["status"],
                "created_at": r["created_at"], "order_count": _counts_map(counts, "orders"), "booking_count": _counts_map(counts, "bookings")}

    @staticmethod
    def _vendor_item(r: dict, owner: dict | None, counts: dict | None) -> dict:
        return {"id": r["id"], "user_id": r["user_id"], "business_name": r["business_name"], "owner_name": (owner or {}).get("full_name") or None,
                "owner_email": (owner or {}).get("email"), "contact_phone": r["contact_phone"], "contact_email": r.get("contact_email"),
                "business_types": list(r.get("business_types") or []), "city": r["city"], "state": r["state"], "verification_status": r["verification_status"],
                "account_status": (owner or {}).get("status"), "created_at": r["created_at"], "product_count": _counts_map(counts, "products"),
                "order_count": _counts_map(counts, "orders"), "booking_count": _counts_map(counts, "bookings")}

    def _tell_vendor(self, row: dict, action: str, reason: str | None) -> None:
        text = {
            "approve": ("Application approved", "Your business has been verified. You can now list products and services."),
            "reject": ("Application not approved", f"Your application was not approved: {reason}"),
            "suspend": ("Account suspended", f"Your vendor account was suspended: {reason}"),
            "reinstate": ("Account reinstated", "Your vendor account is active again."),
        }[action]
        try:
            self.notifier.notify(row["user_id"], text[0], text[1], row["id"])
        except Exception:      # the decision is already stored; a failed notification must not undo or hide it
            pass
