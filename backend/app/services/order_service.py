"""Customer-facing order reads and cancellation. Reads run as the customer (RLS + explicit owner filter)."""

from __future__ import annotations

from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict
from app.repositories.order_gateway import OrderGateway
from app.repositories.order_repository import OrderRepository
from app.services import _catalog
from app.services import _order_views as views


class OrderService:
    def __init__(self, db, admin_db):
        self.orders = OrderRepository(db)
        self.gateway = OrderGateway(admin_db)

    def list(self, user: CurrentUser, *, status, payment_status, page: int, limit: int) -> dict:
        rows, total = self.orders.list_orders(customer_id=user.id, status=status, payment_status=payment_status, page=page, limit=limit)
        return _catalog.page(views.load_summaries(self.orders, rows), total, page, limit)

    def get(self, user: CurrentUser, order_id: UUID) -> dict:
        return views.load_detail(self.orders, self._own(user, order_id))

    def tracking(self, user: CurrentUser, order_id: UUID) -> dict:
        order = self._own(user, order_id)
        vos = self.orders.vendor_orders_for([order["id"]])
        names = {v["id"]: v.get("vendor_name") for v in vos}
        timeline = [{"at": h["created_at"], "scope": "vendor_order" if h.get("vendor_order_id") else "order", "vendor_order_id": h.get("vendor_order_id"),
                     "vendor_name": names.get(h.get("vendor_order_id")), "from_status": h.get("from_status"), "to_status": h["to_status"], "note": h.get("note")}
                    for h in self.orders.history(order["id"])]
        return {"order_id": order["id"], "order_number": order["order_number"], "status": order["status"], "payment_status": order["payment_status"],
                "vendor_orders": [{"id": v["id"], "vendor_name": v.get("vendor_name"), "status": v["status"], "accepted_at": v.get("accepted_at"),
                                   "delivered_at": v.get("delivered_at")} for v in vos],
                "timeline": timeline}

    def cancel(self, user: CurrentUser, order_id: UUID, reason: str) -> dict:
        order = self._own(user, order_id)
        if order["status"] in ("cancelled", "completed"):
            raise conflict("not_cancellable", f"This order is already {order['status']}.")
        self.gateway.cancel_order(order["id"], user.id, "customer", reason)       # atomic: statuses, stock, refund request, payment
        return views.load_detail(self.orders, self.orders.find(order["id"], customer_id=user.id))

    def _own(self, user: CurrentUser, order_id: UUID) -> dict:
        order = self.orders.find(str(order_id), customer_id=user.id)
        if order is None:
            raise NotFoundError("Order not found.")      # same answer for "does not exist" and "belongs to someone else"
        return order
