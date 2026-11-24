from postgrest.types import CountMethod

from app.repositories.base import BaseRepository, Row, day_range


class OrderRepository(BaseRepository):
    """READ access to orders and their children. Always used with a user-scoped client (RLS) except in admin services
    where the admin's own token is used. All writes go through OrderGateway (SQL functions)."""

    table = "orders"

    def __init__(self, client):
        super().__init__(client)

    # ---- orders
    def list_orders(self, *, customer_id: str | None = None, order_ids: list[str] | None = None, status: str | None = None,
                    payment_status: str | None = None, payment_method: str | None = None, number_like: str | None = None,
                    page: int = 1, limit: int = 20) -> tuple[list[Row], int]:
        q = self.client.table("orders").select("*", count=CountMethod.exact)
        if customer_id:
            q = q.eq("customer_id", customer_id)
        if order_ids is not None:
            q = q.in_("id", order_ids or ["00000000-0000-0000-0000-000000000000"])
        if status:
            q = q.eq("status", status)
        if payment_status:
            q = q.eq("payment_status", payment_status)
        if payment_method:
            q = q.eq("payment_method", payment_method)
        if number_like:
            q = q.ilike("order_number", f"*{number_like}*")
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find(self, order_id: str, *, customer_id: str | None = None) -> Row | None:
        q = self.client.table("orders").select("*").eq("id", order_id)
        if customer_id:
            q = q.eq("customer_id", customer_id)
        res = self._run(q.limit(1))
        return res.data[0] if res.data else None

    def find_by_idempotency_key(self, customer_id: str, key: str) -> Row | None:
        res = self._run(self.client.table("orders").select("*").eq("customer_id", customer_id).eq("idempotency_key", key).limit(1))
        return res.data[0] if res.data else None

    def count_coupon_uses(self, customer_id: str, coupon_id: str) -> int:
        q = self.client.table("orders").select("id", count=CountMethod.exact, head=True).eq("customer_id", customer_id).eq("coupon_id", coupon_id).neq("status", "cancelled")
        return self._run(q).count or 0

    # ---- children
    def vendor_orders_for(self, order_ids: list[str]) -> list[Row]:
        if not order_ids:
            return []
        return self._run(self.client.table("vendor_orders").select("*").in_("order_id", order_ids).order("created_at").order("id")).data

    def items_for(self, order_ids: list[str]) -> list[Row]:
        if not order_ids:
            return []
        return self._run(self.client.table("order_items").select("*").in_("order_id", order_ids).order("created_at").order("id")).data

    def items_for_vendor_orders(self, vendor_order_ids: list[str]) -> list[Row]:
        if not vendor_order_ids:
            return []
        return self._run(self.client.table("order_items").select("*").in_("vendor_order_id", vendor_order_ids).order("created_at").order("id")).data

    def history(self, order_id: str) -> list[Row]:
        return self._run(self.client.table("order_status_history").select("*").eq("order_id", order_id).order("created_at").order("id")).data

    def vendor_order_history(self, vendor_order_id: str) -> list[Row]:
        return self._run(self.client.table("order_status_history").select("*").eq("vendor_order_id", vendor_order_id).order("created_at").order("id")).data

    # ---- vendor side
    def list_vendor_orders(self, vendor_id: str, *, status: str | None, page: int, limit: int, date_from=None, date_to=None) -> tuple[list[Row], int]:
        q = self.client.table("vendor_orders").select("*", count=CountMethod.exact).eq("vendor_id", vendor_id).not_.is_("released_at", "null")
        if status:
            q = q.eq("status", status)
        q = day_range(q, "created_at", date_from, date_to)
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find_vendor_order(self, vendor_order_id: str, vendor_id: str | None = None) -> Row | None:
        q = self.client.table("vendor_orders").select("*").eq("id", vendor_order_id)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id).not_.is_("released_at", "null")
        res = self._run(q.limit(1))
        return res.data[0] if res.data else None

    def vendor_order_ids_for_vendor(self, vendor_id: str) -> list[str]:
        return [r["order_id"] for r in self._run(self.client.table("vendor_orders").select("order_id").eq("vendor_id", vendor_id)).data]

    def vendor_names(self, vendor_ids: list[str]) -> dict[str, str]:
        """Public seller names (approved vendors only), from the safe public view."""
        if not vendor_ids:
            return {}
        rows = self._run(self.client.table("vendor_public_profiles").select("id,business_name").in_("id", vendor_ids)).data
        return {r["id"]: r["business_name"] for r in rows}
