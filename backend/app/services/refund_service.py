"""Refund records and their lifecycle (requested -> approved -> processed | failed | rejected).
A refund is 'processed' ONLY after (a) the provider confirmed it (synchronously or by verified webhook) or (b) an admin explicitly
records a manual refund with the external payment reference. Nothing else - not cancellation, not rejection - ever claims money moved."""

from __future__ import annotations

import logging
from uuid import UUID

from app.core.dependencies import CurrentUser
from app.core.exceptions import AppError, NotFoundError, conflict
from app.core.money import q2
from app.core.search import contains_pattern, sanitize_term
from app.integrations.payments.base import PaymentProvider, PaymentProviderError, PaymentProviderNotConfigured
from app.repositories.admin_ops_repository import DirectoryRepository
from app.repositories.commerce_config_repository import AuditRepository
from app.repositories.order_gateway import OrderGateway
from app.repositories.payment_repository import PaymentRepository
from app.schemas.refund import RefundAction, RefundCreate
from app.services import _catalog

logger = logging.getLogger(__name__)


class RefundService:
    def __init__(self, db, admin_db, provider: PaymentProvider):
        self.provider = provider
        self.payments = PaymentRepository(db)             # admin's own token (RLS: admin)
        self.gateway = OrderGateway(admin_db)
        self.audit = AuditRepository(admin_db)

    def list(self, *, status, order_id, payment_id, page: int, limit: int, q=None, date_from=None, date_to=None) -> dict:
        term = sanitize_term(q or "", 60) or None
        if q and not term:
            return _catalog.page([], 0, page, limit)
        expr = None
        if term:
            clauses = [f"provider_refund_id.ilike.{contains_pattern(term)}", f"reason.ilike.{contains_pattern(term)}"]
            order_ids = DirectoryRepository(self.payments.client).order_ids_matching_number(term)
            if order_ids:
                clauses.append(f"order_id.in.({','.join(order_ids)})")
            expr = ",".join(clauses)
        rows, total = self.payments.list_refunds(status=status, order_id=str(order_id) if order_id else None, payment_id=str(payment_id) if payment_id else None,
                                                 or_expr=expr, date_from=date_from, date_to=date_to, page=page, limit=limit)
        return _catalog.page(self._with_numbers(rows), total, page, limit)

    def _with_numbers(self, rows: list[dict]) -> list[dict]:
        orders = self.payments.orders_by_ids([r["order_id"] for r in rows if r.get("order_id")])
        return [{**r, "order_number": (orders.get(r.get("order_id")) or {}).get("order_number")} for r in rows]

    def get(self, refund_id: UUID) -> dict:
        row = self.payments.find_refund(str(refund_id))
        if row is None:
            raise NotFoundError("Refund not found.")
        return self._with_numbers([row])[0]

    def create(self, admin: CurrentUser, body: RefundCreate, idempotency_key: str) -> dict:
        if self.payments.find(str(body.payment_id)) is None:
            raise NotFoundError("Payment not found.")
        # the SQL function locks the payment, refuses amounts above (paid - already requested/processed) and de-duplicates on the key
        refund_id = self.gateway.create_refund(str(body.payment_id), body.amount, body.reason, admin.id, str(body.vendor_order_id) if body.vendor_order_id else None,
                                               f"admin:{idempotency_key}")
        self.audit.record(admin.id, "refund_created", "refund", refund_id, {"amount": float(body.amount), "payment_id": str(body.payment_id)})
        return self.get(UUID(refund_id))

    def act(self, admin: CurrentUser, refund_id: UUID, body: RefundAction) -> dict:
        refund = self.get(refund_id)
        rid = refund["id"]
        if body.action == "approve":
            self.gateway.apply_refund_result(rid, "approved", admin.id, None, None, body.note)
        elif body.action == "reject":
            self.gateway.apply_refund_result(rid, "rejected", admin.id, None, None, body.note)
        elif body.action == "fail":
            self.gateway.apply_refund_result(rid, "failed", admin.id, None, body.note, body.note)
        else:
            self._process(admin, refund, body)
        return self.get(refund_id)

    def _process(self, admin: CurrentUser, refund: dict, body: RefundAction) -> None:
        if refund["status"] != "approved":
            raise conflict("invalid_transition", "Approve the refund before processing it.")
        if body.manual:
            self.gateway.apply_refund_result(refund["id"], "processed", admin.id, body.provider_refund_id, None, f"manual refund: {body.note or ''}".strip())
            return
        if not self.provider.is_configured():
            raise PaymentProviderNotConfigured()
        payment = self.payments.find(refund["payment_id"])
        if not payment.get("provider_payment_id"):
            raise conflict("no_provider_payment", "This payment has no provider payment id; record the refund manually instead.")
        try:
            result = self.provider.refund(provider_payment_id=payment["provider_payment_id"], amount=q2(refund["amount"]), currency=payment["currency"], reference=refund["id"])
        except AppError:
            raise
        except Exception as exc:  # noqa: BLE001
            logger.exception("provider refund failed")
            raise PaymentProviderError() from exc
        if result.status == "processed":
            self.gateway.apply_refund_result(refund["id"], "processed", admin.id, result.provider_refund_id, None, "processed by provider")
        else:
            self.payments.set_refund_provider_reference(refund["id"], result.provider_refund_id)   # stays 'approved' until the webhook confirms
