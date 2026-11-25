from postgrest.types import CountMethod

from app.repositories.base import BaseRepository, Row, day_range


class PaymentRepository(BaseRepository):
    table = "payments"

    def __init__(self, client):
        super().__init__(client)

    def find(self, payment_id: str, *, customer_id: str | None = None) -> Row | None:
        q = self.client.table("payments").select("*").eq("id", payment_id)
        if customer_id:
            q = q.eq("customer_id", customer_id)
        res = self._run(q.limit(1))
        return res.data[0] if res.data else None

    def for_order(self, order_id: str, *, customer_id: str | None = None) -> list[Row]:
        q = self.client.table("payments").select("*").eq("order_id", order_id)
        if customer_id:
            q = q.eq("customer_id", customer_id)
        return self._run(q.order("created_at").order("id")).data

    def for_orders(self, order_ids: list[str]) -> list[Row]:
        if not order_ids:
            return []
        return self._run(self.client.table("payments").select("*").in_("order_id", order_ids).order("created_at")).data

    def list_payments(self, *, status=None, method=None, order_id=None, customer_id=None, needs_review=None, page=1, limit=20,
                      or_expr: str | None = None, date_from=None, date_to=None) -> tuple[list[Row], int]:
        q = self.client.table("payments").select("*", count=CountMethod.exact)
        for col, val in (("status", status), ("method", method), ("order_id", order_id), ("customer_id", customer_id), ("needs_review", needs_review)):
            if val is not None:
                q = q.eq(col, val)
        if or_expr:
            q = q.or_(or_expr)
        q = day_range(q, "created_at", date_from, date_to)
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def orders_by_ids(self, ids: list[str]) -> dict[str, Row]:
        if not ids:
            return {}
        return {r["id"]: r for r in self._run(self.client.table("orders").select("id,order_number,customer_id").in_("id", sorted(set(ids)))).data}

    def events_for(self, payment_id: str) -> list[Row]:
        return self._run(self.client.table("payment_events").select("*").eq("payment_id", payment_id).order("created_at")).data

    # ---- refunds
    def refunds_for_payments(self, payment_ids: list[str]) -> list[Row]:
        if not payment_ids:
            return []
        return self._run(self.client.table("refunds").select("*").in_("payment_id", payment_ids).order("created_at")).data

    def find_refund(self, refund_id: str) -> Row | None:
        res = self._run(self.client.table("refunds").select("*").eq("id", refund_id).limit(1))
        return res.data[0] if res.data else None

    def list_refunds(self, *, status=None, order_id=None, payment_id=None, page=1, limit=20, or_expr: str | None = None, date_from=None, date_to=None) -> tuple[list[Row], int]:
        q = self.client.table("refunds").select("*", count=CountMethod.exact)
        for col, val in (("status", status), ("order_id", order_id), ("payment_id", payment_id)):
            if val is not None:
                q = q.eq(col, val)
        if or_expr:
            q = q.or_(or_expr)
        q = day_range(q, "created_at", date_from, date_to)
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def set_refund_provider_reference(self, refund_id: str, provider_refund_id: str) -> None:
        """Provider accepted the refund but has not finished it: remember its reference (status stays 'approved')."""
        self._run(self.client.table("refunds").update({"provider_refund_id": provider_refund_id}).eq("id", refund_id).eq("status", "approved"))
