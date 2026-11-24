from __future__ import annotations

from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict
from app.core.money import ZERO, q2
from app.repositories.commerce_config_repository import AuditRepository
from app.repositories.order_repository import OrderRepository
from app.repositories.settlement_repository import SettlementRepository
from app.schemas.settlement import MarkPaid
from app.services import _catalog


def _sum(rows, status=None):
    out = {"gross": ZERO, "commission": ZERO, "deductions": ZERO, "net": ZERO}
    for r in rows:
        if status is None or r["status"] == status:
            out["gross"] += q2(r["gross_amount"]); out["commission"] += q2(r["commission_amount"])
            out["deductions"] += q2(r["deductions_amount"]); out["net"] += q2(r["net_amount"])
    return out


class SettlementService:
    """Settlement RECORDS: what each delivered vendor order earned after commission and deductions.
    Nothing here moves money; 'paid' only records a payout the finance team made outside the system."""

    def __init__(self, db, admin_db):
        self.settlements = SettlementRepository(db)
        self.admin_settlements = SettlementRepository(admin_db)
        self.orders = OrderRepository(db)
        self.audit = AuditRepository(admin_db)

    def list(self, *, vendor_id, status, page: int, limit: int) -> dict:
        rows, total = self.settlements.list_settlements(vendor_id=str(vendor_id) if vendor_id else None, status=status, page=page, limit=limit)
        numbers = self._order_numbers(rows)
        items = [{**r, "order_number": numbers.get(r["vendor_order_id"])} for r in rows]
        totals = self.settlements.totals(str(vendor_id) if vendor_id else None)
        summary = {s: _sum(totals, s)["net"] for s in ("pending", "ready", "paid")}
        return {**_catalog.page(items, total, page, limit), "summary": summary}

    def mark_paid(self, admin: CurrentUser, settlement_id: UUID, body: MarkPaid) -> dict:
        current = self.admin_settlements.find(str(settlement_id))
        if current is None:
            raise NotFoundError("Settlement not found.")
        if current["status"] != "ready":
            raise conflict("settlement_not_ready", f"Only a settlement whose payment is confirmed ('ready') can be recorded as paid; this one is '{current['status']}'.")
        updated = self.admin_settlements.mark_paid(str(settlement_id), payout_reference=body.payout_reference, notes=body.notes, admin_id=admin.id)
        if updated is None:
            raise conflict("settlement_not_ready", "This settlement was already updated.")
        self.audit.record(admin.id, "settlement_marked_paid", "settlement", str(settlement_id),
                          {"payout_reference": body.payout_reference, "net_amount": float(q2(updated["net_amount"])), "recorded_manually": True})
        return updated

    def _order_numbers(self, rows) -> dict[str, str]:
        vos = self.orders._run(self.orders.client.table("vendor_orders").select("id,vendor_order_number").in_("id", [r["vendor_order_id"] for r in rows])).data if rows else []
        return {v["id"]: v["vendor_order_number"] for v in vos}
