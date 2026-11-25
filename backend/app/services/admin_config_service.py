from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict, unprocessable
from app.repositories.admin_ops_repository import DirectoryRepository
from app.repositories.commerce_config_repository import AuditRepository, CommissionRepository, SettingsStore
from app.schemas.admin_config import CommissionRuleCreate, CommissionRuleUpdate
from app.services import _pricing as pricing
from app.services._pricing import _parse_ts
from app.services._updates import changes
from app.services.checkout_settings import ALL_KEYS, DESCRIPTIONS, validate_setting

DEFAULTS = {
    "payments.cod_enabled": "off", "payments.online_enabled": "on (still needs a payment provider)",
    "checkout.multi_vendor_policy": "one seller per checkout", "checkout.delivery_charge": "no delivery charge",
    "commission.missing_rule_policy": "block checkout when no commission rule matches", "checkout.payment_window_minutes": "30 minutes",
    "marketplace.require_listing_approval": "listings need approval",
    "services.pickup_charge": "not configured (recorded as 0, flagged on the booking)", "services.dropoff_charge": "not configured (recorded as 0, flagged on the booking)",
    "services.min_notice_hours": "0 hours", "services.max_advance_days": "60 days",
}


class AdminConfigService:
    """Settings and commission rules. Runs with the admin's own token (RLS); every change is written to the audit log."""

    def __init__(self, db, admin_db):
        self.store = SettingsStore(db)
        self.rules = CommissionRepository(db)
        self.audit = AuditRepository(admin_db)
        self.people = DirectoryRepository(db)

    def list_settings(self) -> list[dict]:
        raw = self.store.get_many(ALL_KEYS)
        return [{"key": k, "value": raw.get(k), "configured": k in raw, "description": DESCRIPTIONS[k], "default_behaviour": DEFAULTS[k]} for k in ALL_KEYS]

    def put_setting(self, admin: CurrentUser, key: str, value) -> dict:
        clean = validate_setting(key, value)
        before = self.store.get_many([key]).get(key)
        self.store.put(key, clean, admin.id)
        self.audit.record(admin.id, "setting_changed", "setting", None, {"key": key, "from": before, "to": clean})
        return next(s for s in self.list_settings() if s["key"] == key)

    # ---------------- commission rules
    def list_rules(self) -> list[dict]:
        return self._views(self.rules.list_all())

    def resolve_rule(self, vendor_id, category_id) -> dict:
        """Which ACTIVE product rule would be used right now for this vendor/category - the same function checkout uses."""
        chosen = pricing.select_commission_rule(self.rules.active_product_rules(), str(vendor_id) if vendor_id else "", str(category_id) if category_id else "")
        return {"rule": self._views([chosen])[0] if chosen else None,
                "note": None if chosen else "No active rule matches. Checkout follows the 'commission.missing_rule_policy' setting."}

    def create_rule(self, admin: CurrentUser, body: CommissionRuleCreate) -> dict:
        values = body.model_dump(mode="json", exclude_none=True)
        values.setdefault("effective_from", datetime.now(timezone.utc).isoformat())
        self._check_conflict({**values, "id": None})
        row = self.rules.create({**values, "created_by": admin.id})
        self.audit.record(admin.id, "commission_rule_created", "commission_rule", row["id"], values)
        return self._views([row])[0]

    def update_rule(self, admin: CurrentUser, rule_id: UUID, body: CommissionRuleUpdate) -> dict:
        current = self.rules.find(str(rule_id))
        if current is None:
            raise NotFoundError("Commission rule not found.")
        values = changes(body, nullable={"effective_until"})
        merged = {**current, **values}
        if merged["commission_type"] == "percentage" and float(merged["commission_value"]) > 100:
            raise unprocessable("invalid_commission", "A percentage commission cannot exceed 100.")
        if merged.get("effective_until") and _parse_ts(merged["effective_until"]) <= _parse_ts(merged["effective_from"]):
            raise unprocessable("invalid_commission", "effective_until must be after effective_from.")
        self._check_conflict(merged)
        row = self.rules.update(str(rule_id), values)
        self.audit.record(admin.id, "commission_rule_updated", "commission_rule", str(rule_id), {"changes": values, "before": {k: current.get(k) for k in values}})
        return self._views([row])[0]

    def delete_rule(self, admin: CurrentUser, rule_id: UUID) -> None:
        if self.rules.find(str(rule_id)) is None:
            raise NotFoundError("Commission rule not found.")
        self.rules.delete(str(rule_id))                      # historical orders keep their commission snapshot (rule id is nulled)
        self.audit.record(admin.id, "commission_rule_deleted", "commission_rule", str(rule_id), {})

    # ---------------- helpers
    def _check_conflict(self, rule: dict) -> None:
        """Two ACTIVE rules with the same scope and priority whose validity windows overlap would be resolved by 'newest wins' - an outcome nobody chose.
        Refuse that and ask for a different priority or for the other rule to be deactivated."""
        if not rule.get("is_active", True):
            return
        scope = lambda r: (r["applies_to"], r.get("vendor_id"), r.get("category_id"), r.get("service_category_id"))  # noqa: E731
        start = _parse_ts(rule.get("effective_from")) or datetime.now(timezone.utc)
        end = _parse_ts(rule.get("effective_until"))
        for other in self.rules.list_all():
            if other["id"] == rule.get("id") or not other["is_active"] or scope(other) != scope(rule) or other.get("priority", 0) != rule.get("priority", 0):
                continue
            o_start, o_end = _parse_ts(other.get("effective_from")), _parse_ts(other.get("effective_until"))
            if (end is None or o_start < end) and (o_end is None or start < o_end):
                raise conflict("commission_rule_conflict", f"The active rule '{other['name']}' has the same scope and priority and overlaps in time. "
                               "Change the priority, adjust the dates, or deactivate one of them.", details=[{"conflicts_with": other["id"]}])

    def _views(self, rows: list[dict]) -> list[dict]:
        vendors = self.people.vendor_names([r["vendor_id"] for r in rows if r.get("vendor_id")])
        cats = self.people.category_names("categories", [r["category_id"] for r in rows if r.get("category_id")])
        scats = self.people.category_names("service_categories", [r["service_category_id"] for r in rows if r.get("service_category_id")])
        now = datetime.now(timezone.utc)
        out = []
        for r in rows:
            start, end = _parse_ts(r.get("effective_from")), _parse_ts(r.get("effective_until"))
            state = "inactive" if not r["is_active"] else "scheduled" if start and start > now else "expired" if end and end <= now else "active"
            scope = "vendor_and_category" if r.get("vendor_id") and r.get("category_id") else "vendor" if r.get("vendor_id") else "category" if r.get("category_id") \
                else "service_category" if r.get("service_category_id") else "global"
            out.append({**r, "vendor_name": vendors.get(r.get("vendor_id")), "category_name": cats.get(r.get("category_id")),
                        "service_category_name": scats.get(r.get("service_category_id")), "scope": scope, "state": state})
        return out
