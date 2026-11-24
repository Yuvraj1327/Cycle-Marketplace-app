from datetime import datetime, timezone

from postgrest.types import CountMethod

from app.repositories.base import BaseRepository, Row, day_range


class SettlementRepository(BaseRepository):
    table = "vendor_settlements"

    def __init__(self, client):
        super().__init__(client)

    def list_settlements(self, *, vendor_id: str | None = None, status: str | None = None, page: int = 1, limit: int = 20, date_from=None, date_to=None) -> tuple[list[Row], int]:
        q = self.client.table(self.table).select("*", count=CountMethod.exact)
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        if status:
            q = q.eq("status", status)
        q = day_range(q, "created_at", date_from, date_to)
        offset = (page - 1) * limit
        res = self._run(q.order("created_at", desc=True).order("id").range(offset, offset + limit - 1))
        return res.data, res.count or 0

    def find(self, settlement_id: str) -> Row | None:
        res = self._run(self.client.table(self.table).select("*").eq("id", settlement_id).limit(1))
        return res.data[0] if res.data else None

    def mark_paid(self, settlement_id: str, *, payout_reference: str, notes: str | None, admin_id: str) -> Row | None:
        """Compare-and-set: only a 'ready' settlement can become 'paid' (so double submits can't overwrite a reference)."""
        res = self._run(self.client.table(self.table).update({
            "status": "paid", "payout_reference": payout_reference, "notes": notes, "settled_by": admin_id, "settled_at": datetime.now(timezone.utc).isoformat(),
        }).eq("id", settlement_id).eq("status", "ready"))
        return res.data[0] if res.data else None

    def totals(self, vendor_id: str | None = None) -> list[Row]:
        q = self.client.table(self.table).select("status,gross_amount,commission_amount,deductions_amount,net_amount")
        if vendor_id:
            q = q.eq("vendor_id", vendor_id)
        return self._run(q).data
