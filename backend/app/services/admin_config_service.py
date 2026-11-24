from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError
from app.repositories.commerce_config_repository import AuditRepository, CommissionRepository, SettingsStore
from app.schemas.admin_config import CommissionRuleCreate, CommissionRuleUpdate
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
        return self.rules.list_all()

    def create_rule(self, admin: CurrentUser, body: CommissionRuleCreate) -> dict:
        values = body.model_dump(mode="json", exclude_none=True)
        values.setdefault("effective_from", datetime.now(timezone.utc).isoformat())
        row = self.rules.create({**values, "created_by": admin.id})
        self.audit.record(admin.id, "commission_rule_created", "commission_rule", row["id"], values)
        return row

    def update_rule(self, admin: CurrentUser, rule_id: UUID, body: CommissionRuleUpdate) -> dict:
        if self.rules.find(str(rule_id)) is None:
            raise NotFoundError("Commission rule not found.")
        values = changes(body, nullable={"effective_until"})
        row = self.rules.update(str(rule_id), values)
        self.audit.record(admin.id, "commission_rule_updated", "commission_rule", str(rule_id), values)
        return row

    def delete_rule(self, admin: CurrentUser, rule_id: UUID) -> None:
        if self.rules.find(str(rule_id)) is None:
            raise NotFoundError("Commission rule not found.")
        self.rules.delete(str(rule_id))                      # historical orders keep their commission snapshot (rule id is nulled)
        self.audit.record(admin.id, "commission_rule_deleted", "commission_rule", str(rule_id), {})
