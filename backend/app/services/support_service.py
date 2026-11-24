from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, unprocessable
from app.repositories.booking_repository import BookingRepository
from app.repositories.commerce_config_repository import AuditRepository
from app.repositories.order_repository import OrderRepository
from app.repositories.support_repository import SupportRepository
from app.schemas.support import TicketCreate, TicketUpdate
from app.services import _catalog
from app.services._updates import changes

CUSTOMER_KEYS = ("id", "ticket_number", "type", "subject", "description", "status", "order_id", "service_booking_id", "resolution", "resolved_at", "created_at", "updated_at")


class SupportService:
    """Complaints / support requests / disputes (no chat). Customers create and read their own; admins triage."""

    def __init__(self, db, admin_db):
        self.tickets = SupportRepository(db)
        self.bookings = BookingRepository(db)
        self.orders = OrderRepository(db)
        self.audit = AuditRepository(admin_db)

    def create(self, user: CurrentUser, body: TicketCreate) -> dict:
        if body.service_booking_id and self.bookings.find(str(body.service_booking_id), customer_id=user.id) is None:
            raise unprocessable("invalid_reference", "That booking is not yours.")
        if body.order_id and self.orders.find(str(body.order_id), customer_id=user.id) is None:
            raise unprocessable("invalid_reference", "That order is not yours.")
        row = self.tickets.create({"requester_id": user.id, "type": body.type.value, "subject": body.subject, "description": body.description,
                                   "order_id": str(body.order_id) if body.order_id else None, "service_booking_id": str(body.service_booking_id) if body.service_booking_id else None})
        return self._customer(row)

    def list_own(self, user: CurrentUser, *, status, page: int, limit: int) -> dict:
        rows, total = self.tickets.search(requester_id=user.id, status=status, page=page, limit=limit)
        return _catalog.page([self._customer(r) for r in rows], total, page, limit)

    def get_own(self, user: CurrentUser, ticket_id: UUID) -> dict:
        row = self.tickets.find(str(ticket_id), requester_id=user.id)
        if row is None:
            raise NotFoundError("Ticket not found.")
        return self._customer(row)

    # ---------------- admin
    def admin_list(self, *, status, ticket_type, booking_id, order_id, page: int, limit: int) -> dict:
        rows, total = self.tickets.search(status=status, ticket_type=ticket_type, booking_id=str(booking_id) if booking_id else None,
                                          order_id=str(order_id) if order_id else None, page=page, limit=limit)
        return _catalog.page([self._admin(r) for r in rows], total, page, limit)

    def admin_get(self, ticket_id: UUID) -> dict:
        row = self.tickets.find(str(ticket_id))
        if row is None:
            raise NotFoundError("Ticket not found.")
        return self._admin(row)

    def admin_update(self, admin: CurrentUser, ticket_id: UUID, body: TicketUpdate) -> dict:
        self.admin_get(ticket_id)
        values = changes(body, nullable={"assigned_to", "admin_notes", "resolution"})
        if values.get("status") in ("resolved", "closed"):
            values.setdefault("resolved_at", datetime.now(timezone.utc).isoformat())
        row = self.tickets.modify(str(ticket_id), values)
        self.audit.record(admin.id, "support_ticket_updated", "support_ticket", str(ticket_id), {k: v for k, v in values.items() if k != "resolved_at"})
        return self._admin(row)

    @staticmethod
    def _customer(r: dict) -> dict:
        return {k: r.get(k) for k in CUSTOMER_KEYS}

    @staticmethod
    def _admin(r: dict) -> dict:
        return {**SupportService._customer(r), "requester_id": r["requester_id"], "assigned_to": r.get("assigned_to"), "admin_notes": r.get("admin_notes")}
