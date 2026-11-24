"""Typed access to the transactional SQL functions (service role only). Every money/stock/status mutation goes through here.
Authorisation has ALREADY happened in the service layer; the actor is passed explicitly and recorded in history/audit."""
from typing import Any

from app.repositories.base import BaseRepository


class OrderGateway(BaseRepository):
    table = "orders"

    def __init__(self, admin_client):
        super().__init__(admin_client)

    def _call(self, fn: str, params: dict[str, Any]) -> Any:
        return self._run(self.client.rpc(fn, params)).data

    def vendor_dashboard_summary(self, vendor_id: str) -> dict:
        return self._call("vendor_dashboard_summary", {"p_vendor": vendor_id})

    def place_order(self, payload: dict) -> dict:
        return self._call("place_order", {"p": payload})

    def cancel_order(self, order_id: str, actor_id: str | None, role: str, reason: str | None) -> dict:
        return self._call("cancel_order", {"p_order": order_id, "p_actor": actor_id, "p_role": role, "p_reason": reason})

    def transition_vendor_order(self, vendor_order_id: str, vendor_id: str | None, status: str, actor_id: str | None, role: str, note: str | None) -> dict:
        return self._call("transition_vendor_order", {"p_vo": vendor_order_id, "p_vendor": vendor_id, "p_status": status, "p_actor": actor_id, "p_role": role, "p_note": note})

    def apply_payment_event(self, payload: dict) -> dict:
        return self._call("apply_payment_event", {"p": payload})

    def attach_provider_order(self, payment_id: str, provider: str, provider_order_id: str) -> None:
        self._call("attach_provider_order", {"p_payment": payment_id, "p_provider": provider, "p_provider_order_id": provider_order_id})

    def new_payment_attempt(self, order_id: str, customer_id: str, provider: str) -> str:
        return self._call("new_payment_attempt", {"p_order": order_id, "p_customer": customer_id, "p_provider": provider})

    def record_cod_collection(self, payment_id: str, admin_id: str) -> dict:
        return self._call("record_cod_collection", {"p_payment": payment_id, "p_admin": admin_id})

    def create_refund(self, payment_id: str, amount, reason: str | None, admin_id: str, vendor_order_id: str | None, idempotency_key: str) -> str:
        return self._call("cm_create_refund", {"p_payment": payment_id, "p_amount": float(amount), "p_reason": reason, "p_actor": admin_id,
                                               "p_vendor_order": vendor_order_id, "p_idem": idempotency_key, "p_order": None})

    def apply_refund_result(self, refund_id: str, status: str, admin_id: str | None, provider_refund_id: str | None, failure_reason: str | None, note: str | None) -> dict:
        return self._call("apply_refund_result", {"p_refund": refund_id, "p_status": status, "p_actor": admin_id, "p_provider_refund_id": provider_refund_id,
                                                  "p_failure_reason": failure_reason, "p_note": note})

    def expire_unpaid_orders(self, limit: int = 100) -> int:
        return int(self._call("expire_unpaid_orders", {"p_limit": limit}) or 0)

    def platform_revenue(self, start: str, end: str) -> dict:
        return self._call("platform_revenue", {"p_from": start, "p_to": end})
