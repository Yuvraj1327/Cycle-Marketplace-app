"""Reads/writes for the admin console. Runs with the ADMIN'S OWN token (RLS `is_admin()` + guard triggers); the service-role client is only used for
the aggregate RPCs (AdminGateway) and the audit log."""
from __future__ import annotations

from postgrest.types import CountMethod

from app.repositories.base import BaseRepository, Row
from app.core.search import contains_pattern

PROFILE_SORTS = {"newest": [("created_at", True), ("id", False)], "oldest": [("created_at", False), ("id", False)], "name": [("full_name", False), ("id", False)]}
VENDOR_SORTS = {"newest": [("created_at", True), ("id", False)], "oldest": [("created_at", False), ("id", False)], "name": [("business_name", False), ("id", False)]}


class AdminProfileRepository(BaseRepository):
    table = "profiles"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, role: str, q: str | None, status: str | None, sort: str, page: int, limit: int) -> tuple[list[Row], int]:
        qry = self.client.table(self.table).select("*", count=CountMethod.exact).eq("role", role)
        if status:
            qry = qry.eq("status", status)
        if q:
            pat = contains_pattern(q)                     # q is sanitised by the service
            qry = qry.or_(f"full_name.ilike.{pat},email.ilike.{pat},phone.ilike.{pat}")
        for column, desc in PROFILE_SORTS[sort]:
            qry = qry.order(column, desc=desc)
        offset = (page - 1) * limit
        res = self._run(qry.range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find(self, profile_id: str, role: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", profile_id).eq("role", role).limit(1))
        return res.data[0] if res.data else None

    def many(self, ids: list[str]) -> list[Row]:
        if not ids:
            return []
        return self._run(self.client.table(self.table).select("*").in_("id", ids)).data

    def ids_matching(self, *, role: str, q: str | None = None, status: str | None = None, limit: int = 500) -> list[str]:
        qry = self.client.table(self.table).select("id").eq("role", role)
        if status:
            qry = qry.eq("status", status)
        if q:
            pat = contains_pattern(q)
            qry = qry.or_(f"full_name.ilike.{pat},email.ilike.{pat},phone.ilike.{pat}")
        return [r["id"] for r in self._run(qry.limit(limit)).data]

    def ids_not_status(self, *, role: str, status: str, limit: int = 5000) -> list[str]:
        qry = self.client.table(self.table).select("id,status").eq("role", role).neq("status", status)
        return [r["id"] for r in self._run(qry.limit(limit)).data]

    def set_status(self, profile_id: str, role: str, status: str) -> Row | None:
        res = self._run(self.client.table(self.table).update({"status": status}).eq("id", profile_id).eq("role", role))
        return res.data[0] if res.data else None

    def addresses(self, user_id: str) -> list[Row]:
        return self._run(self.client.table("user_addresses").select("*").eq("user_id", user_id).order("is_default", desc=True).order("created_at")).data


class AdminVendorRepository(BaseRepository):
    table = "vendor_profiles"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, q: str | None, owner_ids_for_q: list[str], business_type: str | None, verification_status: str | None,
               include_users: list[str] | None, exclude_users: list[str] | None, sort: str, page: int, limit: int) -> tuple[list[Row], int]:
        qry = self.client.table(self.table).select("*", count=CountMethod.exact)
        if verification_status:
            qry = qry.eq("verification_status", verification_status)
        if business_type:
            qry = qry.contains("business_types", [business_type])
        if include_users is not None:
            qry = qry.in_("user_id", include_users or ["00000000-0000-0000-0000-000000000000"])
        if exclude_users:
            qry = qry.not_.in_("user_id", exclude_users)
        if q:
            pat = contains_pattern(q)
            clauses = [f"business_name.ilike.{pat}", f"city.ilike.{pat}", f"contact_email.ilike.{pat}", f"contact_phone.ilike.{pat}"]
            if owner_ids_for_q:
                clauses.append(f"user_id.in.({','.join(owner_ids_for_q)})")        # ids come from the database
            qry = qry.or_(",".join(clauses))
        for column, desc in VENDOR_SORTS[sort]:
            qry = qry.order(column, desc=desc)
        offset = (page - 1) * limit
        res = self._run(qry.range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find(self, vendor_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", vendor_id).limit(1))
        return res.data[0] if res.data else None

    def transition(self, vendor_id: str, *, expected: list[str], values: Row) -> Row | None:
        """Compare-and-set on verification_status: a repeated/raced decision updates nothing and returns None."""
        res = self._run(self.client.table(self.table).update(values).eq("id", vendor_id).in_("verification_status", expected))
        return res.data[0] if res.data else None


class AdminGateway(BaseRepository):
    """Service-role aggregates (read-only SQL functions)."""
    table = "profiles"

    def __init__(self, admin_client):
        super().__init__(admin_client)

    def dashboard(self, date_from, date_to) -> dict:
        return self._run(self.client.rpc("admin_dashboard_summary", {"p_from": date_from.isoformat(), "p_to": date_to.isoformat()})).data

    def counts(self, kind: str, ids: list[str]) -> dict:
        if not ids:
            return {}
        return self._run(self.client.rpc("admin_entity_counts", {"p_kind": kind, "p_ids": ids})).data or {}


class AdminNotifier(BaseRepository):
    """Tells the vendor about the decision (a plain in-app notification row; push delivery is a later step)."""
    table = "notifications"

    def __init__(self, admin_client):
        super().__init__(admin_client)

    def notify(self, user_id: str, title: str, message: str, related_id: str) -> None:
        self._run(self.client.table(self.table).insert({"user_id": user_id, "type": "system", "title": title, "message": message,
                                                         "related_type": "vendor_application", "related_id": related_id, "is_read": False}))
