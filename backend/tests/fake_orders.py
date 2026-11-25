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

    def _vendor_user(self, vendor_id):
        v = self.one("vendor_profiles", id=vendor_id)
        return v["user_id"] if v else None

    def _note(self, user, type_, title, message, rel_type, rel_id, key=None):
        """Python twin of public.cm_notify / cm_notify_once (real behaviour is covered against PostgreSQL)."""
        if user is None or (key and any(n["user_id"] == user and n.get("event_key") == key for n in self.rows("notifications"))):
            return
        self.new("notifications", user_id=user, type=type_, title=title, message=message, related_type=rel_type, related_id=rel_id, event_key=key, is_read=False)

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
        self._note(p["customer_id"], "order", "Order placed", f"Your order {order['order_number']} was placed.", "order", order["id"], f"order:{order['id']}:placed")
        if cod:
            for v in (x for x in self.rows("vendor_orders") if x["order_id"] == order["id"]):
                self._note(self._vendor_user(v["vendor_id"]), "order", "New order", f"New order {order['order_number']} is waiting for your response.", "vendor_order", v["id"], f"vo:{v['id']}:new")
        return {"order_id": order["id"], "order_number": order["order_number"], "payment_id": pay["id"], "replay": False}

    # ------------------------------------------------------------------ cancellation / fulfilment
    def _restore(self, vo):
        for it in self.rows("order_items"):
            if it["vendor_order_id"] == vo["id"] and not it["stock_restored_at"]:
                it["stock_restored_at"] = NOW
                prod = self.one("products", id=it["product_id"])
                if prod:
                    prod["stock_quantity"] += it["quantity"]

    def _cancel_vo(self, vo, status, reason, order, actor=None):
        vo["status"] = status
        vo["rejection_reason" if status == "rejected" else "cancellation_reason"] = reason
        vo["cancelled_by"] = actor
        self._restore(vo)
        self._note(order["customer_id"], "order", f"Order {status}", f"Part of order {order['order_number']} was {status}.", "order", order["id"], f"vo:{vo['id']}:{status}:customer")
        owner = self._vendor_user(vo["vendor_id"])
        if status == "cancelled" and vo.get("released_at") and actor != owner:         # trigger notify_vendor_order_cancelled
            self._note(owner, "order", "Order cancelled", f"Order {vo['vendor_order_number']} ({order['order_number']}) was cancelled: {reason}.", "vendor_order", vo["id"], f"vo:{vo['id']}:cancelled")
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
                self._cancel_vo(v, "cancelled", p_reason, o, p_actor)
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
            self._cancel_vo(vo, "rejected", p_note, o, p_actor)
        elif p_status == "cancelled":
            if vo["status"] not in ACTIVE[:-1] and not (p_role == "admin" and vo["status"] == "out_for_delivery"):
                raise cm("invalid_transition", f"{vo['status']}>{p_status}")
            self._cancel_vo(vo, "cancelled", p_note, o, p_actor)
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
            self._note(o["customer_id"], "order", "Order " + p_status.replace("_", " "), f"Order {o['order_number']} is now {p_status.replace('_', ' ')}.", "order", o["id"], f"vo:{vo['id']}:{p_status}")
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
                            self._note(self._vendor_user(v["vendor_id"]), "order", "New order", f"New order {o['order_number']} is waiting for your response.", "vendor_order", v["id"], f"vo:{v['id']}:new")
                    self._note(o["customer_id"], "payment", "Payment received", f"We received your payment for order {o['order_number']}.", "order", o["id"], f"order:{o['id']}:paid")
                    outcome = "applied"
        elif t == "payment.failed" and pay["status"] in ("pending", "processing"):
            pay.update(status="failed", failure_reason=p.get("failure_reason"))
            o["payment_status"] = "failed"
            self._note(o["customer_id"], "payment", "Payment failed", f"Payment for order {o['order_number']} did not go through.", "order", o["id"], f"order:{o['id']}:payfail:{pay['id']}")
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

    def vendor_dashboard_summary(self, p_vendor):
        """Python twin of public.vendor_dashboard_summary (the real one is exercised against PostgreSQL in test_sql_integrity.py)."""
        def by(rows, key="status"):
            out = {}
            for r in rows:
                out[r[key]] = out.get(r[key], 0) + 1
            return out
        vos = [v for v in self.rows("vendor_orders") if v["vendor_id"] == p_vendor and v.get("released_at")]
        done = [v for v in self.rows("vendor_orders") if v["vendor_id"] == p_vendor and v["status"] == "delivered"]
        prods = [p for p in self.rows("products") if p["vendor_id"] == p_vendor]
        books = [b for b in self.rows("service_bookings") if b["vendor_id"] == p_vendor]
        sets = {}
        for s in (s for s in self.rows("vendor_settlements") if s["vendor_id"] == p_vendor):
            t = sets.setdefault(s["status"], {"count": 0, "gross": 0, "commission": 0, "deductions": 0, "net": 0})
            t["count"] += 1
            for k, c in (("gross", "gross_amount"), ("commission", "commission_amount"), ("deductions", "deductions_amount"), ("net", "net_amount")):
                t[k] += float(s[c])
        return {"orders": {"total": len(vos), "by_status": by(vos), "sales_total": sum(float(v["subtotal"]) for v in done),
                           "commission_total": sum(float(v.get("commission_amount") or 0) for v in done)},
                "products": {"total": len(prods), "active": sum(1 for p in prods if p.get("is_active", True) and p.get("approval_status") == "approved"),
                             "pending_approval": sum(1 for p in prods if p.get("approval_status") == "pending"),
                             "rejected": sum(1 for p in prods if p.get("approval_status") == "rejected"),
                             "out_of_stock": sum(1 for p in prods if p.get("stock_quantity") == 0)},
                "bookings": {"total": len(books), "by_status": by(books),
                             "completed_value": sum(float(b.get("final_price") or b["estimated_price"]) for b in books if b["status"] == "completed")},
                "settlements": sets}

    def admin_entity_counts(self, p_kind, p_ids):
        out = {}
        for i in p_ids:
            if p_kind == "customer":
                out[i] = {"orders": sum(1 for o in self.rows("orders") if o["customer_id"] == i), "bookings": sum(1 for b in self.rows("service_bookings") if b["customer_id"] == i)}
            else:
                out[i] = {"products": sum(1 for p in self.rows("products") if p["vendor_id"] == i),
                          "orders": sum(1 for v in self.rows("vendor_orders") if v["vendor_id"] == i and v.get("released_at")),
                          "bookings": sum(1 for b in self.rows("service_bookings") if b["vendor_id"] == i)}
        return out

    def admin_dashboard_summary(self, p_from, p_to):
        """Python twin of public.admin_dashboard_summary (the real one is exercised against PostgreSQL in test_sql_integrity.py)."""
        from datetime import date, timedelta

        def by(rows, key):
            o = {}
            for r in rows:
                o[r[key]] = o.get(r[key], 0) + 1
            return o

        def day(r):
            return str(r["created_at"])[:10]

        d0, d1 = date.fromisoformat(p_from), date.fromisoformat(p_to)
        days = [(d0 + timedelta(days=n)).isoformat() for n in range((d1 - d0).days + 1)]
        customers = [p for p in self.rows("profiles") if p["role"] == "customer"]
        vendors = self.rows("vendor_profiles")
        orders, books = self.rows("orders"), self.rows("service_bookings")
        owners = {p["id"]: p for p in self.rows("profiles")}
        return {
            "period": {"from": p_from, "to": p_to},
            "customers": {"total": len(customers), "by_status": by(customers, "status"), "new_in_period": sum(1 for c in customers if day(c) in days)},
            "vendors": {"total": len(vendors), "by_verification": by(vendors, "verification_status"),
                        "by_account_status": by([{"s": owners[v["user_id"]]["status"]} for v in vendors if v["user_id"] in owners], "s"),
                        "new_in_period": sum(1 for v in vendors if day(v) in days)},
            "orders": {"total": len(orders), "by_status": by(orders, "status"),
                       "value_completed": sum(float(o["total_amount"]) for o in orders if o["status"] == "completed"),
                       "value_confirmed": sum(float(o["total_amount"]) for o in orders if o["status"] == "confirmed")},
            "bookings": {"total": len(books), "by_status": by(books, "status")},
            "series": {
                "orders": [{"day": d, "count": sum(1 for o in orders if day(o) == d), "value": sum(float(o["total_amount"]) for o in orders if day(o) == d and o["status"] != "cancelled")} for d in days],
                "bookings": [{"day": d, "count": sum(1 for b in books if day(b) == d)} for d in days],
                "customers": [{"day": d, "count": sum(1 for c in customers if day(c) == d)} for d in days],
                "vendors": [{"day": d, "count": sum(1 for v in vendors if day(v) == d)} for d in days]},
        }

    # ------------------------------------------------------------------ Step 10: announcements and reports (Python twins of migration 19)
    def admin_send_announcement(self, p_title, p_message, p_type, p_audience, p_user_ids, p_admin):
        if p_audience not in ("customers", "vendors", "specific"):
            raise cm("invalid_audience")
        wanted = set(p_user_ids or [])
        people = [p for p in self.rows("profiles") if p["status"] == "active" and (
            (p_audience == "customers" and p["role"] == "customer") or (p_audience == "vendors" and p["role"] == "vendor")
            or (p_audience == "specific" and p["id"] in wanted and p["role"] in ("customer", "vendor")))]
        if not people:
            raise cm("no_recipients")
        ann = self.new("announcements", title=p_title, message=p_message, type=p_type, audience=p_audience, recipient_count=len(people), created_by=p_admin)
        for p in people:
            self.new("notifications", user_id=p["id"], type=p_type, title=p_title, message=p_message, created_by=p_admin, announcement_id=ann["id"],
                     is_read=False, read_at=None, related_type=None, related_id=None, event_key=None)
        return {"id": ann["id"], "recipient_count": len(people)}

    def admin_announcement_stats(self, p_ids):
        out = {}
        for i in p_ids:
            mine = [n for n in self.rows("notifications") if n.get("announcement_id") == i]
            if mine:
                out[i] = {"delivered": len(mine), "read": sum(1 for n in mine if n["is_read"]), "push_sent": sum(1 for n in mine if n["push_status"] == "sent"),
                          "push_failed": sum(1 for n in mine if n["push_status"] in ("failed", "expired")), "push_pending": sum(1 for n in mine if n["push_status"] in ("pending", "sending"))}
        return out

    def admin_report(self, p_kind, p_from, p_to):
        from datetime import date, timedelta
        d0, d1 = date.fromisoformat(p_from), date.fromisoformat(p_to)
        days = [(d0 + timedelta(days=n)).isoformat() for n in range((d1 - d0).days + 1)]
        day = lambda ts: str(ts)[:10] if ts else None              # noqa: E731
        within = lambda ts: day(ts) in days                        # noqa: E731
        f = lambda v: float(v or 0)                                # noqa: E731

        def by(rows, key):
            o = {}
            for r in rows:
                o[r[key]] = o.get(r[key], 0) + 1
            return o

        def series(rows, ts_key, value=None):
            return [{"day": d, "count": sum(1 for r in rows if day(r[ts_key]) == d), **({"value": sum(f(r[value]) for r in rows if day(r[ts_key]) == d)} if value else {})} for d in days]

        def top(rows, key, n=20):
            return sorted(rows, key=key)[:n]

        orders = [o for o in self.rows("orders") if within(o["created_at"])]
        vos = [v for v in self.rows("vendor_orders") if v["status"] == "delivered" and within(v.get("delivered_at"))]
        vendors, profiles = self.rows("vendor_profiles"), self.rows("profiles")
        vname = {v["id"]: v["business_name"] for v in vendors}
        books = [b for b in self.rows("service_bookings") if within(b["created_at"])]
        if p_kind == "orders":
            live = [o for o in orders if o["status"] != "cancelled"]
            return {"total": len(orders), "value": sum(f(o["total_amount"]) for o in live), "by_status": by(orders, "status"), "by_payment_method": by(orders, "payment_method"),
                    "by_payment_status": by(orders, "payment_status"),
                    "series": [{"day": d, "count": sum(1 for o in orders if day(o["created_at"]) == d), "value": sum(f(o["total_amount"]) for o in live if day(o["created_at"]) == d)} for d in days]}
        if p_kind == "sales":
            vids = {v["id"] for v in vos}
            by_vendor, by_prod = {}, {}
            for v in vos:
                t = by_vendor.setdefault(v["vendor_id"], {"vendor_id": v["vendor_id"], "vendor_name": vname.get(v["vendor_id"]), "orders": 0, "sales": 0.0, "commission": 0.0})
                t["orders"] += 1; t["sales"] += f(v["subtotal"]); t["commission"] += f(v.get("commission_amount"))
            for it in (i for i in self.rows("order_items") if i["vendor_order_id"] in vids):
                t = by_prod.setdefault((it.get("product_id"), it["product_name"]), {"product_id": it.get("product_id"), "product_name": it["product_name"], "units": 0, "sales": 0.0})
                t["units"] += it["quantity"]; t["sales"] += f(it["line_total"])
            return {"delivered_orders": len(vos), "gross_sales": sum(f(v["subtotal"]) for v in vos), "delivery_charges": sum(f(v["delivery_charge"]) for v in vos),
                    "discounts": sum(f(v["discount_amount"]) for v in vos), "commission": sum(f(v.get("commission_amount")) for v in vos),
                    "series": [{"day": d, "count": sum(1 for v in vos if day(v["delivered_at"]) == d), "value": sum(f(v["subtotal"]) for v in vos if day(v["delivered_at"]) == d)} for d in days],
                    "by_vendor": top(by_vendor.values(), lambda t: (-t["sales"], t["vendor_name"] or "")), "by_product": top(by_prod.values(), lambda t: (-t["sales"], t["product_name"]))}
        if p_kind == "vendors":
            owners = {p["id"]: p for p in profiles}
            perf = []
            for v in vendors:
                mine = [x for x in vos if x["vendor_id"] == v["id"]]
                perf.append({"vendor_id": v["id"], "business_name": v["business_name"], "verification_status": v["verification_status"],
                             "products": sum(1 for p in self.rows("products") if p["vendor_id"] == v["id"]), "orders_delivered": len(mine), "sales": sum(f(x["subtotal"]) for x in mine),
                             "bookings_completed": sum(1 for b in self.rows("service_bookings") if b["vendor_id"] == v["id"] and b["status"] == "completed" and within(b.get("completed_at")))})
            return {"total": len(vendors), "new_in_period": sum(1 for v in vendors if within(v["created_at"])), "by_verification": by(vendors, "verification_status"),
                    "by_account_status": by([{"s": owners[v["user_id"]]["status"]} for v in vendors if v["user_id"] in owners], "s"), "series": series(vendors, "created_at"),
                    "performance": top(perf, lambda t: (-t["sales"], t["business_name"]))}
        if p_kind == "customers":
            cust = [p for p in profiles if p["role"] == "customer"]
            active = {o["customer_id"] for o in orders} | {b["customer_id"] for b in books}
            names = {p["id"]: p.get("full_name") for p in cust}
            agg = {}
            for o in orders:
                t = agg.setdefault(o["customer_id"], {"customer_id": o["customer_id"], "full_name": names.get(o["customer_id"]), "orders": 0, "order_value": 0.0, "bookings": 0})
                t["orders"] += 1; t["order_value"] += f(o["total_amount"]) if o["status"] != "cancelled" else 0
                t["bookings"] = sum(1 for b in books if b["customer_id"] == o["customer_id"])
            return {"total": len(cust), "new_in_period": sum(1 for c in cust if within(c["created_at"])), "by_status": by(cust, "status"), "active_in_period": len(active),
                    "orders_in_period": len(orders), "bookings_in_period": len(books), "series": series(cust, "created_at"),
                    "top_customers": top(agg.values(), lambda t: (-t["orders"], -t["order_value"], t["full_name"] or ""), 10)}
        if p_kind == "services":
            bids = {b["id"] for b in books}
            pr = [r for r in self.rows("pickup_dropoff_requests") if r["booking_id"] in bids]
            cats = {c["id"]: c["name"] for c in self.rows("service_categories")}
            by_v, by_c = {}, {}
            for b in books:
                t = by_v.setdefault(b["vendor_id"], {"vendor_id": b["vendor_id"], "vendor_name": vname.get(b["vendor_id"]), "total": 0, "completed": 0, "cancelled_or_rejected": 0})
                t["total"] += 1; t["completed"] += b["status"] == "completed"; t["cancelled_or_rejected"] += b["status"] in ("cancelled", "rejected")
                c = by_c.setdefault(cats.get(b.get("service_category_id"), "Uncategorised"), {"category_name": cats.get(b.get("service_category_id"), "Uncategorised"), "total": 0})
                c["total"] += 1
            return {"total": len(books), "by_status": by(books, "status"),
                    "completed_value": sum(f(b.get("final_price") or b["estimated_price"]) for b in books if b["status"] == "completed"), "series": series(books, "created_at"),
                    "by_vendor": top(by_v.values(), lambda t: (-t["total"], t["vendor_name"] or "")), "by_category": top(by_c.values(), lambda t: (-t["total"], t["category_name"])),
                    "pickup": {"bookings_needing_pickup": sum(1 for b in books if b.get("needs_pickup_dropoff")), "requests": len(pr),
                               "pickup_by_status": by(pr, "pickup_status"), "delivery_by_status": by(pr, "delivery_status")}}
        if p_kind == "payments":
            pays = [p for p in self.rows("payments") if within(p["created_at"])]
            paid = [p for p in self.rows("payments") if p["status"] in ("successful", "partially_refunded", "refunded") and within(p.get("paid_at"))]
            rfs = [r for r in self.rows("refunds") if within(r["created_at"])]
            agg = lambda rows, key: {k: {"count": sum(1 for r in rows if r[key] == k), "amount": sum(f(r["amount"]) for r in rows if r[key] == k)} for k in {r[key] for r in rows}}  # noqa: E731
            return {"total": len(pays), "by_status": agg(pays, "status"), "by_method": agg(pays, "method"), "collected": sum(f(p["amount"]) for p in paid),
                    "collected_by_method": agg(paid, "method"), "refunded": sum(f(r["amount"]) for r in self.rows("refunds") if r["status"] == "processed" and within(r.get("processed_at"))),
                    "refunds_by_status": agg(rfs, "status"), "commission": sum(f(v.get("commission_amount")) for v in vos),
                    "series": [{"day": d, "count": sum(1 for p in paid if day(p["paid_at"]) == d), "value": sum(f(p["amount"]) for p in paid if day(p["paid_at"]) == d)} for d in days]}
        raise cm("invalid_report")

    # ------------------------------------------------------------------ Step 11: device tokens and the push outbox (Python twins of migration 20)
    def register_device_token(self, p_user, p_token, p_platform, p_app, p_label, p_version):
        if len(p_token) < 20 or p_platform not in ("android", "ios", "web") or p_app not in ("customer", "vendor"):
            raise cm("invalid_device")
        row = self.one("device_tokens", token=p_token)
        if row:
            row.update(user_id=p_user, platform=p_platform, app=p_app, device_label=p_label, app_version=p_version, is_active=True, last_error=None, last_seen_at=self.db.now())
        else:
            row = self.new("device_tokens", user_id=p_user, token=p_token, platform=p_platform, app=p_app, device_label=p_label, app_version=p_version, is_active=True, last_error=None, last_seen_at=self.db.now())
        mine = sorted((r for r in self.rows("device_tokens") if r["user_id"] == p_user and r["is_active"]), key=lambda r: (r["last_seen_at"], r["created_at"]), reverse=True)
        for r in mine[10:]:
            r["is_active"] = False
        return row["id"]

    def deactivate_device_token(self, p_user, p_token):
        row = self.one("device_tokens", token=p_token, user_id=p_user, is_active=True)
        if row:
            row.update(is_active=False, last_error="signed out")
        return 1 if row else 0

    def claim_pending_pushes(self, p_limit, p_max_attempts, p_max_age):
        hours = int(str(p_max_age).split()[0])
        out = []
        for n in sorted(self.rows("notifications"), key=lambda r: r["created_at"]):
            if n.get("push_status") not in ("pending", "sending"):
                continue
            if self.db.age_hours(n["created_at"]) > hours:
                n.update(push_status="expired", push_error="too old to push")
                continue
            if n["push_attempts"] >= p_max_attempts:
                n.update(push_status="failed", push_error=n.get("push_error") or "gave up after repeated attempts")
                continue
            owner = self.db.profile(n["user_id"])
            if n["push_status"] == "pending" and not (owner and owner["status"] == "active"):
                n.update(push_status="skipped", push_error="recipient account is not active")
                continue
            if n["push_status"] == "sending" or n.get("push_next_at") and n["push_next_at"] > self.db.now():     # leased, or waiting for its back-off
                continue
            if len(out) >= p_limit:
                break
            n.update(push_status="sending", push_attempts=n["push_attempts"] + 1)
            toks = sorted((t for t in self.rows("device_tokens") if t["user_id"] == n["user_id"] and t["is_active"]), key=lambda t: t["last_seen_at"], reverse=True)
            out.append({"id": n["id"], "user_id": n["user_id"], "type": n["type"], "title": n["title"], "message": n["message"], "related_type": n.get("related_type"),
                        "related_id": n.get("related_id"), "attempts": n["push_attempts"], "tokens": [{"id": t["id"], "token": t["token"], "platform": t["platform"], "app": t["app"]} for t in toks]})
        return out

    def finish_push(self, p_id, p_status, p_error, p_retry_seconds, p_invalid_token_ids):
        if p_status not in ("sent", "failed", "skipped", "pending"):
            raise cm("invalid_push_status")
        for t in self.rows("device_tokens"):
            if t["id"] in (p_invalid_token_ids or []):
                t.update(is_active=False, last_error="rejected by the push provider")
        n = self.one("notifications", id=p_id)
        if n and n["push_status"] == "sending":
            n.update(push_status=p_status, push_error=(p_error or None) and p_error[:300])
            if p_status == "sent":
                n["push_sent_at"] = self.db.now()
            if p_status == "pending":
                n["push_next_at"] = self.db.future(p_retry_seconds or 60)

    def admin_push_status(self):
        by, dev = {}, {}
        for n in self.rows("notifications"):
            by[n["push_status"]] = by.get(n["push_status"], 0) + 1
        for t in self.rows("device_tokens"):
            if t["is_active"]:
                dev[t["app"]] = dev.get(t["app"], 0) + 1
        pend = [n["created_at"] for n in self.rows("notifications") if n["push_status"] == "pending"]
        fails = [{"id": n["id"], "title": n["title"], "push_error": n.get("push_error"), "push_attempts": n["push_attempts"], "created_at": n["created_at"]} for n in self.rows("notifications") if n["push_status"] == "failed"]
        return {"by_status": by, "active_devices": dev, "oldest_pending": min(pend) if pend else None, "recent_failures": fails[:5]}

