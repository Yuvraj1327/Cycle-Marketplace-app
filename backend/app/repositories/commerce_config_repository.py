"""Service-role reads/writes of configuration that customers must not see directly: coupons, commission rules, settings, audit."""
from app.repositories.base import BaseRepository, Row


class CouponRepository(BaseRepository):
    table = "coupons"

    def __init__(self, client):
        super().__init__(client)

    def find_by_code(self, code: str) -> Row | None:
        res = self._run(self.client.table("coupons").select("*").ilike("code", code.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")).limit(5))
        return next((r for r in res.data if r["code"].upper() == code.upper()), None)


class CommissionRepository(BaseRepository):
    table = "commission_rules"

    def __init__(self, client):
        super().__init__(client)

    def active_product_rules(self) -> list[Row]:
        return self._run(self.client.table(self.table).select("*").eq("is_active", True).eq("applies_to", "product")).data

    def list_all(self) -> list[Row]:
        return self._run(self.client.table(self.table).select("*").order("priority", desc=True).order("created_at", desc=True)).data

    def find(self, rule_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", rule_id).limit(1))
        return res.data[0] if res.data else None


class SettingsStore(BaseRepository):
    table = "platform_settings"

    def __init__(self, client):
        super().__init__(client)

    def get_many(self, keys: list[str]) -> dict[str, object]:
        rows = self._run(self.client.table(self.table).select("key,value").in_("key", keys)).data
        return {r["key"]: r["value"] for r in rows}

    def put(self, key: str, value, admin_id: str | None) -> Row:
        existing = self._run(self.client.table(self.table).select("key").eq("key", key).limit(1)).data
        if existing:
            return self._run(self.client.table(self.table).update({"value": value, "updated_by": admin_id}).eq("key", key)).data[0]
        return self._run(self.client.table(self.table).insert({"key": key, "value": value, "updated_by": admin_id})).data[0]


class AuditRepository(BaseRepository):
    table = "audit_log"

    def __init__(self, client):
        super().__init__(client)

    def record(self, actor_id: str, action: str, entity_type: str, entity_id: str | None, details: dict | None = None) -> None:
        self._run(self.client.table(self.table).insert({"actor_id": actor_id, "actor_role": "admin", "action": action, "entity_type": entity_type,
                                                         "entity_id": entity_id, "details": details or {}}))

    def for_entity(self, entity_type: str, entity_id: str) -> list[Row]:
        return self._run(self.client.table(self.table).select("*").eq("entity_type", entity_type).eq("entity_id", entity_id).order("created_at")).data
