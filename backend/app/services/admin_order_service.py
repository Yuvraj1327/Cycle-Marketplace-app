from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, unprocessable
from app.core.money import ZERO, q2
from app.core.search import sanitize_term
from app.repositories.commerce_config_repository import AuditRepository
from app.repositories.order_gateway import OrderGateway
from app.repositories.order_repository import OrderRepository
from app.repositories.payment_repository import PaymentRepository
from app.repositories.settlement_repository import SettlementRepository
from app.schemas.order import AdminStatusUpdate
from app.services import _catalog
from app.services import _order_views as views


class AdminOrderService:
    """Admin reads run with the ADMIN'S OWN token (RLS is_admin policies); mutations go through the audited SQL functions."""

    def __init__(self, db, admin_db):
        self.db = db
        self.orders = OrderRepository(db)
        self.payments = PaymentRepository(db)
        self.settlements = SettlementRepository(db)
        self.gateway = OrderGateway(admin_db)
        self.audit = AuditRepository(admin_db)

    # ---------------- orders
    def list(self, *, status, payment_status, payment_method, vendor_id, customer_id, q, page: int, limit: int) -> dict:
        order_ids = self.orders.vendor_order_ids_for_vendor(str(vendor_id)) if vendor_id else None
        number = sanitize_term(q or "", 40) or None
        if q and not number:
            return _catalog.page([], 0, page, limit)
        rows, total = self.orders.list_orders(customer_id=str(customer_id) if customer_id else None, order_ids=order_ids, status=status,
                                              payment_status=payment_status, payment_method=payment_method, number_like=number, page=page, limit=limit)
        return _catalog.page(self._admin_views(rows) if rows else [], total, page, limit)

    def get(self, order_id: UUID) -> dict:
        order = self.orders.find(str(order_id))
        if order is None:
            raise NotFoundError("Order not found.")
        return self._admin_views([order])[0]

    def set_status(self, admin: CurrentUser, order_id: UUID, body: AdminStatusUpdate) -> dict:
        order = self.orders.find(str(order_id))
        if order is None:
            raise NotFoundError("Order not found.")
        if body.vendor_order_id:
            if body.status in ("cancelled", "rejected") and not (body.reason or "").strip():
                raise unprocessable("reason_required", "A reason is required when cancelling or rejecting.")
            self.gateway.transition_vendor_order(str(body.vendor_order_id), None, body.status, admin.id, "admin", body.reason)
        else:
            if body.status != "cancelled":
                raise unprocessable("unsupported_status", "An order's own status is derived from its vendor orders; admins can only cancel it "
                                    "(or change one vendor order by sending vendor_order_id).")
            if not (body.reason or "").strip():
                raise unprocessable("reason_required", "A reason is required to cancel an order.")
            self.gateway.cancel_order(order["id"], admin.id, "admin", body.reason)
        self.audit.record(admin.id, "order_status_changed", "order", order["id"], {"status": body.status, "vendor_order_id": str(body.vendor_order_id) if body.vendor_order_id else None, "reason": body.reason})
        return self.get(order_id)

    def expire_unpaid(self, admin: CurrentUser) -> dict:
        n = self.gateway.expire_unpaid_orders(200)
        self.audit.record(admin.id, "unpaid_orders_expired", "order", None, {"count": n})
        return {"cancelled": n}

    # ---------------- payments
    def list_payments(self, *, status, method, order_id, customer_id, needs_review, page: int, limit: int) -> dict:
        rows, total = self.payments.list_payments(status=status, method=method, order_id=str(order_id) if order_id else None,
                                                  customer_id=str(customer_id) if customer_id else None, needs_review=needs_review, page=page, limit=limit)
        return _catalog.page([self._payment(p) for p in rows], total, page, limit)

    def payment_detail(self, payment_id: UUID) -> dict:
        p = self.payments.find(str(payment_id))
        if p is None:
            raise NotFoundError("Payment not found.")
        order = self.orders.find(p["order_id"]) if p.get("order_id") else None
        return {**self._payment(p), "order": {k: order[k] for k in ("id", "order_number", "status", "payment_status", "total_amount")} if order else None,
                "events": self.payments.events_for(p["id"]), "refunds": self.payments.refunds_for_payments([p["id"]])}

    def revenue(self, start: datetime | None, end: datetime | None) -> dict:
        end = end or datetime.now(timezone.utc)
        start = start or end - timedelta(days=30)
        if start >= end:
            raise unprocessable("invalid_period", "`from` must be before `to`.")
        r = self.gateway.platform_revenue(start.isoformat(), end.isoformat())
        rows = self.settlements.totals()
        by = {s: {"count": 0, "net": ZERO} for s in ("pending", "ready", "paid", "cancelled")}
        for row in rows:
            by[row["status"]]["count"] += 1
            by[row["status"]]["net"] += q2(row["net_amount"])
        return {"period_from": start, "period_to": end, "collected": r["collected"], "refunded": r["refunded"],
                "net_collected": q2(r["collected"]) - q2(r["refunded"]), "commission_earned": r["commission_earned"], "cod_outstanding": r["cod_outstanding"],
                "orders_placed": r["orders_placed"], "orders_completed": r["orders_completed"],
                "settlements": {k: {"count": v["count"], "net": float(v["net"])} for k, v in by.items()}}

    # ---------------- helpers
    @staticmethod
    def _payment(p: dict) -> dict:
        return {**views.payment_out(p), "customer_id": p["customer_id"], "needs_review": p.get("needs_review", False), "review_reason": p.get("review_reason"),
                "recorded_by": p.get("recorded_by"), "provider_payment_id": p.get("provider_payment_id")}

    def _admin_views(self, rows: list[dict]) -> list[dict]:
        ids = [o["id"] for o in rows]
        vos, items = self.orders.vendor_orders_for(ids), self.orders.items_for(ids)
        pays = self.payments.for_orders(ids)
        refunds = self.payments.refunds_for_payments([p["id"] for p in pays])
        profiles = {p["id"]: p for p in self.orders._run(self.db.table("profiles").select("id,full_name,email,phone").in_("id", sorted({o["customer_id"] for o in rows}))).data}
        out = []
        for o in rows:
            mine = [p for p in pays if p["order_id"] == o["id"]]
            out.append({**views.detail(o, vos, items), "cancelled_by_role": o.get("cancelled_by_role"), "customer": profiles.get(o["customer_id"]),
                        "payments": [self._payment(p) for p in mine], "refunds": [r for r in refunds if r["payment_id"] in {p["id"] for p in mine}]})
        return out

    def _admin_view(self, o: dict) -> dict:
        return self._admin_views([o])[0]
