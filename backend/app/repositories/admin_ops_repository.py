"""Step 10 admin repositories. Reads/writes run with the ADMIN'S OWN token (RLS `is_admin()`); the gateway uses the service role for
the read-only aggregates and the atomic announcement function, after the route has verified the caller is an admin."""
from postgrest.types import CountMethod

from app.core.search import contains_pattern
from app.repositories.base import BaseRepository, Row, day_range


def _page(q, order: list[tuple[str, bool]], page: int, limit: int):
    for col, desc in order:
        q = q.order(col, desc=desc)
    offset = (page - 1) * limit
    return q.range(offset, offset + limit - 1)


class CouponAdminRepository(BaseRepository):
    table = "coupons"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, q: str | None, is_active: bool | None, page: int, limit: int) -> tuple[list[Row], int]:
        query = self.client.table(self.table).select("*", count=CountMethod.exact)
        if is_active is not None:
            query = query.eq("is_active", is_active)
        if q:
            pat = contains_pattern(q)                                                # q is sanitised by the service
            query = query.or_(f"code.ilike.{pat},description.ilike.{pat}")
        res = self._run(_page(query, [("created_at", True), ("id", False)], page, limit))
        return res.data, res.count or 0

    def find(self, coupon_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", coupon_id).limit(1))
        return res.data[0] if res.data else None

    def find_by_code(self, code: str) -> Row | None:
        rows = self._run(self.client.table(self.table).select("*").ilike("code", code.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")).limit(5)).data
        return next((r for r in rows if r["code"].upper() == code.upper()), None)


class AnnouncementRepository(BaseRepository):
    table = "announcements"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, type: str | None, audience: str | None, page: int, limit: int) -> tuple[list[Row], int]:
        q = self.client.table(self.table).select("*", count=CountMethod.exact)
        if type:
            q = q.eq("type", type)
        if audience:
            q = q.eq("audience", audience)
        res = self._run(_page(q, [("created_at", True), ("id", False)], page, limit))
        return res.data, res.count or 0

    def find(self, announcement_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", announcement_id).limit(1))
        return res.data[0] if res.data else None

    def notifications(self, *, type: str | None, user_id: str | None, announcement_id: str | None, user_ids: list[str] | None, date_from, date_to,
                      page: int, limit: int) -> tuple[list[Row], int]:
        q = self.client.table("notifications").select("*", count=CountMethod.exact)
        if type:
            q = q.eq("type", type)
        if user_id:
            q = q.eq("user_id", user_id)
        if announcement_id:
            q = q.eq("announcement_id", announcement_id)
        if user_ids is not None:
            q = q.in_("user_id", user_ids or ["00000000-0000-0000-0000-000000000000"])
        q = day_range(q, "created_at", date_from, date_to)
        res = self._run(_page(q, [("created_at", True), ("id", False)], page, limit))
        return res.data, res.count or 0


class OpsGateway(BaseRepository):
    """Service-role SQL functions: atomic announcement fan-out and read-only reports."""

    table = "announcements"

    def __init__(self, admin_client):
        super().__init__(admin_client)

    def send_announcement(self, *, title: str, message: str, type: str, audience: str, user_ids: list[str] | None, admin_id: str) -> dict:
        return self._run(self.client.rpc("admin_send_announcement", {"p_title": title, "p_message": message, "p_type": type, "p_audience": audience,
                                                                      "p_user_ids": user_ids or [], "p_admin": admin_id})).data

    def announcement_stats(self, ids: list[str]) -> dict:
        if not ids:
            return {}
        return self._run(self.client.rpc("admin_announcement_stats", {"p_ids": ids})).data or {}

    def report(self, kind: str, date_from, date_to) -> dict:
        return self._run(self.client.rpc("admin_report", {"p_kind": kind, "p_from": date_from.isoformat(), "p_to": date_to.isoformat()})).data


class DirectoryRepository(BaseRepository):
    """Names for ids and id lookups for free-text search (customer / vendor / business names)."""

    table = "profiles"

    def __init__(self, client):
        super().__init__(client)

    def profiles(self, ids: list[str], cols: str = "id,full_name,email,phone,role") -> dict[str, Row]:
        if not ids:
            return {}
        return {r["id"]: r for r in self._run(self.client.table("profiles").select(cols).in_("id", sorted(set(ids)))).data}

    def vendor_names(self, ids: list[str]) -> dict[str, str]:
        if not ids:
            return {}
        rows = self._run(self.client.table("vendor_profiles").select("id,business_name").in_("id", sorted(set(ids)))).data
        return {r["id"]: r["business_name"] for r in rows}

    def vendor_user_id(self, vendor_id: str) -> str | None:
        rows = self._run(self.client.table("vendor_profiles").select("user_id").eq("id", vendor_id).limit(1)).data
        return rows[0]["user_id"] if rows else None

    def category_names(self, table: str, ids: list[str]) -> dict[str, str]:
        if not ids:
            return {}
        return {r["id"]: r["name"] for r in self._run(self.client.table(table).select("id,name").in_("id", sorted(set(ids)))).data}

    def customer_ids_matching(self, term: str, limit: int = 50) -> list[str]:
        """Profiles whose name, e-mail or phone contains `term` (already sanitised)."""
        pat = contains_pattern(term)
        rows = self._run(self.client.table("profiles").select("id").or_(f"full_name.ilike.{pat},email.ilike.{pat},phone.ilike.{pat}").limit(limit)).data
        return [r["id"] for r in rows]

    def vendor_ids_matching(self, term: str, limit: int = 50) -> list[str]:
        rows = self._run(self.client.table("vendor_profiles").select("id").ilike("business_name", contains_pattern(term)).limit(limit)).data
        return [r["id"] for r in rows]

    def order_ids_matching_number(self, term: str, limit: int = 100) -> list[str]:
        rows = self._run(self.client.table("orders").select("id").ilike("order_number", contains_pattern(term)).limit(limit)).data
        return [r["id"] for r in rows]


class AuditReader(BaseRepository):
    table = "audit_log"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, entity_type: str | None, entity_id: str | None, action: str | None, actor_id: str | None, page: int, limit: int) -> tuple[list[Row], int]:
        q = self.client.table(self.table).select("*", count=CountMethod.exact)
        if entity_type:
            q = q.eq("entity_type", entity_type)
        if entity_id:
            q = q.eq("entity_id", entity_id)
        if action:
            q = q.eq("action", action)
        if actor_id:
            q = q.eq("actor_id", actor_id)
        res = self._run(_page(q, [("created_at", True), ("id", False)], page, limit))
        return res.data, res.count or 0


class VendorOrderAdminRepository(BaseRepository):
    """Flat list of vendor orders (fulfilment records). Only orders RELEASED to the vendor (confirmed COD / verified online payment)."""

    table = "vendor_orders"

    def __init__(self, client):
        super().__init__(client)

    def search(self, *, status: str | None, vendor_id: str | None, order_ids: list[str] | None, vendor_ids: list[str] | None, date_from, date_to,
               page: int, limit: int) -> tuple[list[Row], int]:
        q = self.client.table(self.table).select("*", count=CountMethod.exact).not_.is_("released_at", "null")
        if status:
            q = q.eq("status", status)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        if order_ids is not None:
            q = q.in_("order_id", order_ids or ["00000000-0000-0000-0000-000000000000"])
        if vendor_ids is not None:
            q = q.in_("vendor_id", vendor_ids or ["00000000-0000-0000-0000-000000000000"])
        q = day_range(q, "created_at", date_from, date_to)
        res = self._run(_page(q, [("created_at", True), ("id", False)], page, limit))
        return res.data, res.count or 0

    def orders(self, ids: list[str]) -> dict[str, Row]:
        if not ids:
            return {}
        return {r["id"]: r for r in self._run(self.client.table("orders").select("*").in_("id", sorted(set(ids)))).data}

    def item_counts(self, vendor_order_ids: list[str]) -> dict[str, int]:
        if not vendor_order_ids:
            return {}
        out: dict[str, int] = {}
        for r in self._run(self.client.table("order_items").select("vendor_order_id,quantity").in_("vendor_order_id", vendor_order_ids)).data:
            out[r["vendor_order_id"]] = out.get(r["vendor_order_id"], 0) + int(r["quantity"])
        return out
