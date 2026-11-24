"""In-memory stand-in for the Step 5 SQL functions, used ONLY to test the Python/API layer. The real functions are tested against
PostgreSQL in test_sql_integrity.py; this keeps the same observable contract (CM:<code> errors, idempotency, stock, state machine)."""
from decimal import Decimal

from postgrest.exceptions import APIError

NOW = "2026-01-01T00:00:00+00:00"
VENDOR_FLOW = {("pending", "accepted"), ("accepted", "preparing"), ("preparing", "ready_for_dispatch"), ("ready_for_dispatch", "out_for_delivery"),
               ("ready_for_dispatch", "delivered"), ("out_for_delivery", "delivered")}
ACTIVE = ("pending", "accepted", "preparing", "ready_for_dispatch", "out_for_delivery")
REFUND_FLOW = {("requested", "approved"), ("requested", "rejected"), ("approved", "processed"), ("approved", "failed"), ("approved", "rejected"), ("failed", "approved")}


def cm(code, detail=""):
    return APIError({"message": f"CM:{code}:{detail}", "code": "P0001", "details": None, "hint": None})


def D(x):
    return Decimal(str(x))


class FakeOrderSQL:
    def __init__(self, db):
        self.db = db
        self.counter = 0
        self.calls = []

    def rows(self, t):
        return self.db.rows(t)

    def one(self, t, **kw):
        return next((r for r in self.rows(t) if all(r.get(k) == v for k, v in kw.items())), None)

    def new(self, t, **row):
        self.counter += 1
        row = self.db.apply_defaults(t, {**row})
        self.rows(t).append(row)
        return row

    def call(self, fn, params, actor):
        self.calls.append((fn, params))
        return getattr(self, fn)(**params)

    # ------------------------------------------------------------------ checkout
    def place_order(self, p):
        key = p["idempotency_key"]
        if not key or len(key) < 8:
            raise cm("idempotency_key_required")
        ex = self.one("orders", customer_id=p["customer_id"], idempotency_key=key)
        if ex:
            if ex["request_hash"] != p["request_hash"]:
                raise cm("idempotency_key_reuse")
            pay = [x for x in self.rows("payments") if x["order_id"] == ex["id"]][-1]
            return {"order_id": ex["id"], "order_number": ex["order_number"], "payment_id": pay["id"], "replay": True}
        wanted = {}
        for vo in p["vendor_orders"]:
            for it in vo["items"]:
                prod = self.one("products", id=it["product_id"])
                if not prod:
                    raise cm("product_unavailable", it["product_id"])
                if prod["vendor_id"] != vo["vendor_id"]:
                    raise cm("invalid_vendor", prod["id"])
                if not prod["is_active"] or prod["approval_status"] != "approved" or not prod["is_available"]:
                    raise cm("product_unavailable", prod["id"])
                if D(prod["price"]) != D(it["unit_price"]):
                    raise cm("price_changed", prod["id"])
                wanted[prod["id"]] = wanted.get(prod["id"], 0) + it["quantity"]
                if prod["stock_quantity"] < wanted[prod["id"]]:
                    raise cm("insufficient_stock", prod["id"])
        if D(p["total_amount"]) <= 0:
            raise cm("invalid_total")
        if p.get("coupon_id"):
            c = self.one("coupons", id=p["coupon_id"])
            if not c or (c["usage_limit"] is not None and c["used_count"] >= c["usage_limit"]):
                raise cm("coupon_unavailable", p.get("coupon_code"))
            c["used_count"] += 1
        for pid, q in wanted.items():
            self.one("products", id=pid)["stock_quantity"] -= q
        cod = p["payment_method"] == "cod"
        order = self.new("orders", order_number=f"ORD-{len(self.rows('orders')) + 1:08d}", customer_id=p["customer_id"], status="confirmed" if cod else "pending",
                         payment_method=p["payment_method"], payment_status="pending", delivery_address_id=p.get("delivery_address_id"), delivery_address=p["delivery_address"],
                         subtotal=float(D(p["subtotal"])), delivery_charge=float(D(p["delivery_charge"])), discount_amount=float(D(p["discount_amount"])),
                         total_amount=float(D(p["total_amount"])), coupon_id=p.get("coupon_id"), coupon_code=p.get("coupon_code"), customer_note=p.get("customer_note"),
                         idempotency_key=key, request_hash=p["request_hash"], payment_due_at=None if cod else p.get("payment_due_at"), cancelled_reason=None,
                         cancelled_at=None, cancelled_by_role=None)
        for vo in p["vendor_orders"]:
            v = self.new("vendor_orders", vendor_order_number=f"VO-{len(self.rows('vendor_orders')) + 1:08d}", order_id=order["id"], vendor_id=vo["vendor_id"],
                         vendor_name=vo["vendor_name"], status="pending", subtotal=float(D(vo["subtotal"])), delivery_charge=float(D(vo["delivery_charge"])),
                         discount_amount=float(D(vo["discount_amount"])), total_amount=float(D(vo["total_amount"])), commission_amount=float(D(vo["commission_amount"])),
                         commission_rule_id=vo.get("commission_rule_id"), released_at=NOW if cod else None, accepted_at=None, delivered_at=None, vendor_note=None,
                         rejection_reason=None, cancellation_reason=None)
            for it in vo["items"]:
                self.new("order_items", order_id=order["id"], vendor_order_id=v["id"], product_id=it["product_id"], product_name=it["name"], product_brand=it.get("brand"),
                         product_model=it.get("model"), product_condition=it["condition"], product_image_path=it.get("image_path"), unit_price=float(D(it["unit_price"])),
                         quantity=it["quantity"], line_total=float(D(it["unit_price"]) * it["quantity"]), commission_amount=float(D(it["commission_amount"])),
                         commission_rule_id=it.get("commission_rule_id"), stock_restored_at=None)
        pay = self.new("payments", customer_id=p["customer_id"], order_id=order["id"], method=p["payment_method"], provider=p.get("provider"), provider_order_id=None,
                       provider_payment_id=None, amount=float(D(p["total_amount"])), currency=p.get("currency", "INR"), status="pending", failure_reason=None, paid_at=None,
                       refunded_amount=0.0, needs_review=False, review_reason=None, recorded_by=None)
        cart = self.one("carts", user_id=p["customer_id"])
        bought = set(wanted)
        self.db.tables["cart_items"] = [i for i in self.rows("cart_items") if not (cart and i["cart_id"] == cart["id"] and i["product_id"] in bought)]
        return {"order_id": order["id"], "order_number": order["order_number"], "payment_id": pay["id"], "replay": False}

    # ------------------------------------------------------------------ cancellation / fulfilment
    def _restore(self, vo):
        for it in self.rows("order_items"):
            if it["vendor_order_id"] == vo["id"] and not it["stock_restored_at"]:
                it["stock_restored_at"] = NOW
                prod = self.one("products", id=it["product_id"])
                if prod:
                    prod["stock_quantity"] += it["quantity"]

    def _cancel_vo(self, vo, status, reason, order):
        vo["status"] = status
        vo["rejection_reason" if status == "rejected" else "cancellation_reason"] = reason
        self._restore(vo)
        pay = next((x for x in self.rows("payments") if x["order_id"] == order["id"] and x["status"] in ("successful", "partially_refunded")), None)
        if pay:
            self.new("refunds", payment_id=pay["id"], order_id=order["id"], vendor_order_id=vo["id"], amount=vo["total_amount"], reason=reason, status="requested",
                     provider=pay["provider"], provider_refund_id=None, failure_reason=None, requested_by=None, processed_by=None, processed_at=None, idempotency_key=f"vo-cancel:{vo['id']}")

    def _finalize(self, order, role, reason):
        vos = [v for v in self.rows("vendor_orders") if v["order_id"] == order["id"]]
        if all(v["status"] in ("rejected", "cancelled") for v in vos):
            order.update(status="cancelled", cancelled_reason=reason, cancelled_by_role=role, cancelled_at=NOW)
            if order["payment_status"] in ("pending", "processing", "failed"):
                order["payment_status"] = "cancelled"
            for p in self.rows("payments"):
                if p["order_id"] == order["id"] and p["status"] in ("pending", "processing"):
                    p["status"] = "cancelled"
        elif any(v["status"] == "delivered" for v in vos) and all(v["status"] in ("delivered", "rejected", "cancelled") for v in vos):
            order["status"] = "completed"

    def cancel_order(self, p_order, p_actor, p_role, p_reason):
        o = self.one("orders", id=p_order)
        if not o or (p_role == "customer" and o["customer_id"] != p_actor):
            raise cm("not_found", "order")
        if o["status"] in ("cancelled", "completed"):
            raise cm("not_cancellable", o["status"])
        vos = [v for v in self.rows("vendor_orders") if v["order_id"] == o["id"]]
        if p_role == "customer" and any(v["status"] not in ("pending", "accepted", "rejected", "cancelled") for v in vos):
            raise cm("not_cancellable", "preparation_started")
        for v in vos:
            if v["status"] in ACTIVE:
                self._cancel_vo(v, "cancelled", p_reason, o)
        self._finalize(o, p_role, p_reason)
        return {"order_id": o["id"]}

    def transition_vendor_order(self, p_vo, p_vendor, p_status, p_actor, p_role, p_note):
        vo = self.one("vendor_orders", id=p_vo)
        if not vo or (p_vendor and vo["vendor_id"] != p_vendor):
            raise cm("not_found", "vendor_order")
        o = self.one("orders", id=vo["order_id"])
        if o["status"] == "cancelled" or not vo["released_at"]:
            raise cm("order_not_active", o["status"])
        if p_status == "rejected":
            if vo["status"] != "pending":
                raise cm("invalid_transition", f"{vo['status']}>{p_status}")
            self._cancel_vo(vo, "rejected", p_note, o)
        elif p_status == "cancelled":
            if vo["status"] not in ACTIVE[:-1] and not (p_role == "admin" and vo["status"] == "out_for_delivery"):
                raise cm("invalid_transition", f"{vo['status']}>{p_status}")
            self._cancel_vo(vo, "cancelled", p_note, o)
        else:
            if (vo["status"], p_status) not in VENDOR_FLOW:
                raise cm("invalid_transition", f"{vo['status']}>{p_status}")
            vo["status"] = p_status
            if p_status == "accepted":
                vo["accepted_at"] = NOW
            if p_status == "delivered":
                vo["delivered_at"] = NOW
                self.new("vendor_settlements", vendor_id=vo["vendor_id"], vendor_order_id=vo["id"], gross_amount=vo["subtotal"], commission_amount=vo["commission_amount"],
                         deductions_amount=0.0, net_amount=vo["subtotal"] - vo["commission_amount"],
                         status="ready" if o["payment_status"] in ("successful", "partially_refunded") else "pending", payout_reference=None, settled_at=None)
            if p_note:
                vo["vendor_note"] = p_note
        self._finalize(o, p_role, p_note)
        return {"vendor_order_id": vo["id"], "status": vo["status"]}

    # ------------------------------------------------------------------ payments
    def attach_provider_order(self, p_payment, p_provider, p_provider_order_id):
        pay = self.one("payments", id=p_payment)
        if pay and pay["status"] == "pending":
            pay.update(provider=p_provider, provider_order_id=p_provider_order_id, status="processing")
            self.one("orders", id=pay["order_id"])["payment_status"] = "processing"

    def new_payment_attempt(self, p_order, p_customer, p_provider):
        o = self.one("orders", id=p_order, customer_id=p_customer)
        if not o:
            raise cm("not_found", "order")
        if o["payment_method"] != "online":
            raise cm("not_online_order")
        if o["status"] != "pending" or o["payment_status"] == "successful":
            raise cm("order_not_payable", o["status"])
        open_ = next((p for p in self.rows("payments") if p["order_id"] == p_order and p["status"] in ("pending", "processing")), None)
        if open_:
            return open_["id"]
        return self.new("payments", customer_id=p_customer, order_id=p_order, method="online", provider=p_provider, provider_order_id=None, provider_payment_id=None,
                        amount=o["total_amount"], currency="INR", status="pending", failure_reason=None, paid_at=None, refunded_amount=0.0, needs_review=False,
                        review_reason=None, recorded_by=None)["id"]

    def apply_payment_event(self, p):
        if any(e["provider"] == p["provider"] and e["event_id"] == p["event_id"] for e in self.rows("payment_events")):
            return {"outcome": "duplicate"}
        ev = self.new("payment_events", provider=p["provider"], event_id=p["event_id"], event_type=p["event_type"], outcome="received")
        pay = next((x for x in reversed(self.rows("payments")) if x["provider"] == p["provider"] and p.get("provider_order_id") and x["provider_order_id"] == p["provider_order_id"]), None)
        if not pay:
            ev["outcome"] = "unmatched"
            return {"outcome": "unmatched"}
        ev["payment_id"] = pay["id"]
        o = self.one("orders", id=pay["order_id"])
        t, outcome = p["event_type"], "ignored"
        if t == "payment.succeeded":
            if pay["status"] in ("successful", "refunded", "partially_refunded"):
                outcome = "already_applied"
            elif p.get("amount") is None or D(p["amount"]) != D(pay["amount"]) or (p.get("currency") or pay["currency"]).upper() != pay["currency"].upper():
                pay["needs_review"] = True
                outcome = "amount_mismatch"
            else:
                pay.update(status="successful", paid_at=NOW, provider_payment_id=p.get("provider_payment_id"))
                o["payment_status"] = "successful"
                if o["status"] == "cancelled":
                    self.new("refunds", payment_id=pay["id"], order_id=o["id"], vendor_order_id=None, amount=pay["amount"], reason="late payment", status="requested",
                             provider=pay["provider"], provider_refund_id=None, failure_reason=None, requested_by=None, processed_by=None, processed_at=None, idempotency_key=f"late-payment:{pay['id']}")
                    outcome = "applied_late_refund_requested"
                else:
                    o["status"] = "confirmed"
                    for v in self.rows("vendor_orders"):
                        if v["order_id"] == o["id"] and not v["released_at"] and v["status"] == "pending":
                            v["released_at"] = NOW
                    outcome = "applied"
        elif t == "payment.failed" and pay["status"] in ("pending", "processing"):
            pay.update(status="failed", failure_reason=p.get("failure_reason"))
            o["payment_status"] = "failed"
            outcome = "applied"
        elif t == "payment.processing" and pay["status"] == "pending":
            pay["status"] = "processing"
            outcome = "applied"
        ev["outcome"] = outcome
        return {"outcome": outcome, "payment_id": pay["id"], "order_id": o["id"]}

    def record_cod_collection(self, p_payment, p_admin):
        pay = self.one("payments", id=p_payment)
        if not pay:
            raise cm("not_found", "payment")
        if pay["method"] != "cod" or pay["status"] != "pending":
            raise cm("not_collectable", pay["status"])
        o = self.one("orders", id=pay["order_id"])
        if not any(v["order_id"] == o["id"] and v["status"] in ("out_for_delivery", "delivered") for v in self.rows("vendor_orders")):
            raise cm("not_dispatched")
        pay.update(status="successful", paid_at=NOW, recorded_by=p_admin)
        o["payment_status"] = "successful"
        for s in self.rows("vendor_settlements"):
            if s["status"] == "pending" and self.one("vendor_orders", id=s["vendor_order_id"])["order_id"] == o["id"]:
                s["status"] = "ready"
        return {"payment_id": p_payment, "status": "successful"}

    # ------------------------------------------------------------------ refunds
    def cm_create_refund(self, p_payment, p_amount, p_reason, p_actor, p_vendor_order, p_idem, p_order):
        ex = self.one("refunds", idempotency_key=p_idem)
        if ex:
            return ex["id"]
        pay = self.one("payments", id=p_payment)
        if not pay:
            raise cm("not_found", "payment")
        if pay["status"] not in ("successful", "partially_refunded"):
            raise cm("payment_not_refundable", pay["status"])
        committed = sum(D(r["amount"]) for r in self.rows("refunds") if r["payment_id"] == p_payment and r["status"] in ("requested", "approved", "processed"))
        if p_amount <= 0:
            raise cm("invalid_amount")
        if committed + D(p_amount) > D(pay["amount"]):
            raise cm("refund_exceeds", str(D(pay["amount"]) - committed))
        return self.new("refunds", payment_id=p_payment, order_id=pay["order_id"], vendor_order_id=p_vendor_order, amount=float(p_amount), reason=p_reason, status="requested",
                        provider=pay["provider"], provider_refund_id=None, failure_reason=None, requested_by=p_actor, processed_by=None, processed_at=None, idempotency_key=p_idem)["id"]

    def apply_refund_result(self, p_refund, p_status, p_actor, p_provider_refund_id, p_failure_reason, p_note):
        r = self.one("refunds", id=p_refund)
        if not r:
            raise cm("not_found", "refund")
        if (r["status"], p_status) not in REFUND_FLOW:
            raise cm("invalid_transition", f"{r['status']}>{p_status}")
        r["status"] = p_status
        r["provider_refund_id"] = p_provider_refund_id or r["provider_refund_id"]
        r["failure_reason"] = p_failure_reason if p_status == "failed" else None
        if p_status == "processed":
            r.update(processed_at=NOW, processed_by=p_actor)
            pay = self.one("payments", id=r["payment_id"])
            pay["refunded_amount"] = float(D(pay["refunded_amount"]) + D(r["amount"]))
            pay["status"] = "refunded" if D(pay["refunded_amount"]) >= D(pay["amount"]) else "partially_refunded"
            self.one("orders", id=pay["order_id"])["payment_status"] = pay["status"]
        return {"refund_id": p_refund, "status": p_status}

    def expire_unpaid_orders(self, p_limit=100):
        return 0

    def platform_revenue(self, p_from, p_to):
        pays = [p for p in self.rows("payments") if p["status"] in ("successful", "partially_refunded", "refunded")]
        return {"collected": sum(p["amount"] for p in pays), "refunded": sum(r["amount"] for r in self.rows("refunds") if r["status"] == "processed"),
                "commission_earned": sum(v["commission_amount"] for v in self.rows("vendor_orders") if v["status"] == "delivered"),
                "cod_outstanding": sum(p["amount"] for p in self.rows("payments") if p["method"] == "cod" and p["status"] == "pending"),
                "orders_placed": len(self.rows("orders")), "orders_completed": sum(1 for o in self.rows("orders") if o["status"] == "completed")}
