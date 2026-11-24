"""Online payment flow around a PaymentProvider adapter. No provider => nothing here pretends to succeed.

initiate:   order+payment row exist (stock reserved) -> provider creates its order -> we store the provider reference (processing)
webhook:    raw body + signature verified by the adapter -> canonical events -> public.apply_payment_event (idempotent, atomic)
reconcile:  ask the provider for the true state of a payment and apply it through the very same path
Only a VERIFIED provider event (or an admin recording COD cash) can mark a payment successful."""
import logging

from app.core.dependencies import CurrentUser
from app.core.exceptions import AppError, NotFoundError, conflict
from app.core.money import q2
from app.integrations.payments.base import PaymentProvider, PaymentProviderError, PaymentProviderNotConfigured
from app.repositories.base import Row
from app.repositories.commerce_config_repository import AuditRepository
from app.repositories.order_gateway import OrderGateway
from app.repositories.order_repository import OrderRepository
from app.repositories.payment_repository import PaymentRepository
from app.services import _order_views as views

logger = logging.getLogger(__name__)

_RECONCILE_EVENT = {"succeeded": "payment.succeeded", "failed": "payment.failed", "processing": "payment.processing", "cancelled": "payment.cancelled"}


class PaymentService:
    def __init__(self, db, admin_db, provider: PaymentProvider):
        self.provider = provider
        self.orders = OrderRepository(db)
        self.payments = PaymentRepository(db)
        self.admin_payments = PaymentRepository(admin_db)
        self.gateway = OrderGateway(admin_db)
        self.audit = AuditRepository(admin_db)

    # ---------------- customer ----------------
    def initiate(self, payment: Row, order: Row, customer_id: str) -> tuple[Row, dict]:
        """Start the provider's payment for an existing pending attempt. Raises (and does not touch state) on provider failure."""
        if not self.provider.is_configured():
            raise PaymentProviderNotConfigured()
        try:
            init = self.provider.create_payment(reference=payment["id"], amount=q2(payment["amount"]), currency=payment["currency"],
                                                customer_id=customer_id, description=f"Order {order['order_number']}")
        except AppError:
            raise
        except Exception as exc:  # noqa: BLE001 - any adapter failure is a provider error, never a crash with internals
            logger.exception("payment provider failed to create a payment")
            raise PaymentProviderError() from exc
        self.gateway.attach_provider_order(payment["id"], self.provider.name, init.provider_order_id)
        return self.admin_payments.find(payment["id"]) or payment, init.client_payload

    def create_for_order(self, user: CurrentUser, order_id) -> dict:
        """(Re)start payment for an unpaid online order: first attempt after a provider problem, or a retry after a failure."""
        order = self.orders.find(str(order_id), customer_id=user.id)
        if order is None:
            raise NotFoundError("Order not found.")
        if order["payment_method"] != "online":
            raise conflict("not_online_order", "Only online orders can be paid online.")
        if not self.provider.is_configured():
            raise PaymentProviderNotConfigured()
        payment_id = self.gateway.new_payment_attempt(order["id"], user.id, self.provider.name)   # returns the open attempt if one exists
        payment = self.admin_payments.find(payment_id)
        if payment["status"] == "processing" and payment.get("provider_order_id"):
            payload = self.provider.client_payload(provider_order_id=payment["provider_order_id"], amount=q2(payment["amount"]), currency=payment["currency"])
        else:
            payment, payload = self.initiate(payment, order, user.id)
        return {**views.payment_out(payment), "client_payload": payload}

    def get(self, user: CurrentUser, payment_id) -> dict:
        row = self.payments.find(str(payment_id), customer_id=user.id)
        if row is None:
            raise NotFoundError("Payment not found.")
        return views.payment_out(row)

    def for_order(self, user: CurrentUser, order_id) -> list[dict]:
        if self.orders.find(str(order_id), customer_id=user.id) is None:
            raise NotFoundError("Order not found.")
        return [views.payment_out(p) for p in self.payments.for_order(str(order_id), customer_id=user.id)]

    # ---------------- provider -> us ----------------
    def handle_webhook(self, headers, body: bytes) -> dict:
        events = self.provider.parse_webhook(headers, body)      # verifies the signature; raises InvalidWebhookSignature
        results = []
        for ev in events:
            res = self.gateway.apply_payment_event({
                "provider": self.provider.name, "event_id": ev.event_id, "event_type": ev.event_type,
                "provider_order_id": ev.provider_order_id, "provider_payment_id": ev.provider_payment_id, "provider_refund_id": ev.provider_refund_id,
                "amount": str(ev.amount) if ev.amount is not None else None, "currency": ev.currency, "failure_reason": ev.failure_reason})
            results.append({"event_id": ev.event_id, "outcome": str(res.get("outcome"))})
            if res.get("outcome") in ("amount_mismatch", "applied_late_refund_requested", "applied_duplicate_refund_requested"):
                logger.warning("payment event %s needs review: %s", ev.event_id, res.get("outcome"))
        return {"received": len(events), "results": results}

    # ---------------- admin ----------------
    def reconcile(self, admin: CurrentUser, payment_id) -> dict:
        payment = self.admin_payments.find(str(payment_id))
        if payment is None:
            raise NotFoundError("Payment not found.")
        if payment["method"] != "online" or not payment.get("provider_order_id"):
            raise conflict("not_reconcilable", "Only online payments that reached the provider can be reconciled.")
        if not self.provider.is_configured():
            raise PaymentProviderNotConfigured()
        state = self.provider.fetch_payment(provider_order_id=payment["provider_order_id"])
        event_type = _RECONCILE_EVENT.get(state.status)
        if event_type is None:
            return {"payment_id": payment["id"], "provider_status": state.status, "outcome": "no_change"}
        res = self.gateway.apply_payment_event({
            "provider": self.provider.name, "event_id": f"reconcile:{payment['id']}:{state.status}:{state.provider_payment_id or ''}", "event_type": event_type,
            "provider_order_id": payment["provider_order_id"], "provider_payment_id": state.provider_payment_id,
            "amount": str(state.amount) if state.amount is not None else None, "currency": state.currency, "failure_reason": state.failure_reason})
        self.audit.record(admin.id, "payment_reconciled", "payment", payment["id"], {"provider_status": state.status, "outcome": res.get("outcome")})
        return {"payment_id": payment["id"], "provider_status": state.status, "outcome": res.get("outcome")}

    def collect_cod(self, admin: CurrentUser, payment_id) -> dict:
        if self.admin_payments.find(str(payment_id)) is None:
            raise NotFoundError("Payment not found.")
        return self.gateway.record_cod_collection(str(payment_id), admin.id)   # audit row is written by the SQL function
