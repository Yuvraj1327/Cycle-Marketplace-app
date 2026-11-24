"""Vendor-side fulfilment. The vendor id comes from the authenticated, APPROVED vendor (never from the request); every order is
re-checked to belong to that vendor, and the SQL function checks it again. Vendors cannot touch payment status, commission or totals."""

from __future__ import annotations

from uuid import UUID

from app.core.dependencies import ApprovedVendor
from app.core.exceptions import NotFoundError, unprocessable
from app.core.money import ZERO, q2
from app.repositories.base import Row
from app.repositories.order_gateway import OrderGateway
from app.repositories.order_repository import OrderRepository
from app.repositories.settlement_repository import SettlementRepository
from app.schemas.order import VendorAccept, VendorReject, VendorStatusUpdate
from app.services import _catalog
from app.services import _order_views as views

ALLOWED_PATCH = {"preparing", "ready_for_dispatch", "out_for_delivery", "delivered", "cancelled"}


class VendorOrderService:
    def __init__(self, db, admin_db):
        self.orders = OrderRepository(db)
        self.settlement_repo = SettlementRepository(db)
        self.gateway = OrderGateway(admin_db)

    def list(self, vendor: ApprovedVendor, *, status, page: int, limit: int, date_from=None, date_to=None) -> dict:
        rows, total = self.orders.list_vendor_orders(vendor.vendor["id"], status=status, page=page, limit=limit, date_from=date_from, date_to=date_to)
        parents = {o["id"]: o for o in self.orders.list_orders(order_ids=[r["order_id"] for r in rows], page=1, limit=100)[0]} if rows else {}
        items = self.orders.items_for_vendor_orders([r["id"] for r in rows])
        return _catalog.page([self._list_item(r, parents.get(r["order_id"]), items) for r in rows if parents.get(r["order_id"])], total, page, limit)

    def get(self, vendor: ApprovedVendor, vendor_order_id: UUID) -> dict:
        return self._detail(self._own(vendor, vendor_order_id))

    def accept(self, vendor: ApprovedVendor, vendor_order_id: UUID, body: VendorAccept) -> dict:
        return self._act(vendor, vendor_order_id, "accepted", body.note)

    def reject(self, vendor: ApprovedVendor, vendor_order_id: UUID, body: VendorReject) -> dict:
        return self._act(vendor, vendor_order_id, "rejected", body.reason)

    def update_status(self, vendor: ApprovedVendor, vendor_order_id: UUID, body: VendorStatusUpdate) -> dict:
        target = body.status.value
        if target not in ALLOWED_PATCH:
            raise unprocessable("use_dedicated_endpoint", "Use POST .../accept or POST .../reject for those changes.")
        if target == "cancelled" and len((body.note or "").strip()) < 3:
            raise unprocessable("reason_required", "Give a reason (note) when cancelling an order.")
        return self._act(vendor, vendor_order_id, target, body.note)

    def timeline(self, vendor: ApprovedVendor, vendor_order_id: UUID) -> list[dict]:
        vo = self._own(vendor, vendor_order_id)
        return [{"at": h["created_at"], "scope": "vendor_order", "vendor_order_id": vo["id"], "vendor_name": None, "from_status": h.get("from_status"),
                 "to_status": h["to_status"], "note": h.get("note")} for h in self.orders.vendor_order_history(vo["id"])]

    def dashboard(self, vendor: ApprovedVendor) -> dict:
        return self.gateway.vendor_dashboard_summary(vendor.vendor["id"])

    def settlements(self, vendor: ApprovedVendor, *, status, page: int, limit: int, date_from=None, date_to=None) -> dict:
        rows, total = self.settlement_repo.list_settlements(vendor_id=vendor.vendor["id"], status=status, page=page, limit=limit, date_from=date_from, date_to=date_to)
        return _catalog.page(rows, total, page, limit)

    # ---------------- internals
    def _act(self, vendor: ApprovedVendor, vendor_order_id: UUID, status: str, note: str | None) -> dict:
        vo = self._own(vendor, vendor_order_id)                                    # 404 for other vendors' / unreleased orders
        self.gateway.transition_vendor_order(vo["id"], vendor.vendor["id"], status, vendor.user.id, "vendor", note)
        return self._detail(self._own(vendor, vendor_order_id))

    def _own(self, vendor: ApprovedVendor, vendor_order_id: UUID) -> Row:
        vo = self.orders.find_vendor_order(str(vendor_order_id), vendor_id=vendor.vendor["id"])
        if vo is None:
            raise NotFoundError("Order not found.")
        return vo

    def _list_item(self, vo: Row, parent: Row, items: list[Row]) -> dict:
        return {"id": vo["id"], "vendor_order_number": vo["vendor_order_number"], "order_id": parent["id"], "order_number": parent["order_number"],
                "status": vo["status"], "payment_method": parent["payment_method"], "payment_status": parent["payment_status"], "subtotal": vo["subtotal"],
                "total_amount": vo["total_amount"], "commission_amount": vo.get("commission_amount"),
                "item_count": sum(i["quantity"] for i in items if i["vendor_order_id"] == vo["id"]), "placed_at": parent["created_at"]}

    def _detail(self, vo: Row) -> dict:
        parent = self.orders.find(vo["order_id"])
        items = self.orders.items_for_vendor_orders([vo["id"]])
        address = parent["delivery_address"]       # fulfilment details only: name, phone, address (no e-mail, no account data)
        commission = q2(vo["commission_amount"]) if vo.get("commission_amount") is not None else ZERO
        return {**self._list_item(vo, parent, items), "delivery_charge": vo["delivery_charge"], "discount_amount": vo["discount_amount"],
                "net_payable": q2(vo["subtotal"]) - commission, "delivery_address": address, "customer_note": parent.get("customer_note"),
                "accepted_at": vo.get("accepted_at"), "delivered_at": vo.get("delivered_at"), "vendor_note": vo.get("vendor_note"),
                "rejection_reason": vo.get("rejection_reason"), "cancellation_reason": vo.get("cancellation_reason"),
                "items": [views.item_out(i) for i in items]}
