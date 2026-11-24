"""In-memory stand-in for the Step 6 SQL functions (API-layer tests only; the real functions are tested on PostgreSQL in test_sql_integrity.py)."""
from decimal import Decimal

from tests.fake_orders import cm

OPEN = ("pending", "accepted", "picked_up", "in_service", "ready_for_delivery")
NOW = "2026-01-01T00:00:00+00:00"


def D(x):
    return Decimal(str(x))


class FakeServiceSQL:
    # ------------------------------------------------------------------ helpers
    def _notify(self, user, type_, title, message, rel_type, rel_id, key):
        if user is None or any(n["user_id"] == user and n.get("event_key") == key for n in self.rows("notifications")):
            return
        self.new("notifications", user_id=user, type=type_, title=title, message=message, related_type=rel_type, related_id=rel_id, event_key=key, is_read=False)

    def _notify_admins(self, type_, title, message, rel_type, rel_id, key):
        for p in self.rows("profiles"):
            if p["role"] == "admin" and p["status"] == "active":
                self._notify(p["id"], type_, title, message, rel_type, rel_id, key)

    def _history(self, b, old, new, actor, note):
        self.new("booking_status_history", booking_id=b["id"], from_status=old, to_status=new, changed_by=actor, note=note)

    def _vendor_ok(self, vendor_id):
        return self.db.vendor_ok(vendor_id)

    def _pickup(self, booking_id):
        return self.one("pickup_dropoff_requests", booking_id=booking_id)

    # ------------------------------------------------------------------ create
    def create_service_booking(self, p):
        cust = self.db.profile(p["customer_id"])
        if not cust or cust["role"] != "customer" or cust["status"] != "active":
            raise cm("account_inactive")
        vs = self.one("vendor_services", id=p["service_id"])
        if not vs or not vs["is_active"] or not vs["is_available"]:
            raise cm("service_unavailable")
        if not self._vendor_ok(vs["vendor_id"]):
            raise cm("vendor_unavailable")
        cat = self.one("service_categories", id=vs["service_category_id"])
        if not cat["is_active"]:
            raise cm("service_unavailable")
        vp = self.one("vendor_profiles", id=vs["vendor_id"])
        needs = bool(p.get("needs_pickup_dropoff"))
        if needs and not vp["pickup_available"]:
            raise cm("pickup_not_offered")
        if any(b["customer_id"] == p["customer_id"] and b["vendor_service_id"] == vs["id"] and str(b["preferred_date"]) == str(p["preferred_date"])
               and str(b["preferred_slot_start"])[:5] == p["slot_start"][:5] and b["status"] in OPEN for b in self.rows("service_bookings")):
            raise cm("duplicate_booking")
        b = self.new("service_bookings", booking_number=f"BKG-{len(self.rows('service_bookings')) + 1:08d}", customer_id=p["customer_id"], vendor_id=vs["vendor_id"],
                     vendor_service_id=vs["id"], service_name=vs["name"], service_category_id=vs["service_category_id"], vendor_name=vp["business_name"],
                     cycle_brand=p.get("cycle_brand"), cycle_model=p.get("cycle_model"), cycle_details=p.get("cycle_details"), issue_description=p["issue_description"],
                     preferred_date=p["preferred_date"], preferred_slot_start=p["slot_start"], preferred_slot_end=p["slot_end"], needs_pickup_dropoff=needs,
                     estimated_price=float(vs["price"]), estimated_duration_minutes=vs.get("estimated_duration_minutes"), final_price=None, price_change_reason=None,
                     status="pending", vendor_notes=None, rejection_reason=None, cancellation_reason=None, cancelled_by=None, accepted_at=None, completed_at=None,
                     completion_notes=None, confirmed_date=None, confirmed_slot_start=None, confirmed_slot_end=None)
        self._history(b, None, "pending", p["customer_id"], None)
        if needs:
            self.new("pickup_dropoff_requests", booking_id=b["id"], pickup_address_id=p.get("pickup_address_id"), pickup_address=p["pickup_address"],
                     dropoff_address_id=p.get("dropoff_address_id"), dropoff_address=p["dropoff_address"], scheduled_pickup_at=None, scheduled_delivery_at=None,
                     pickup_charge=float(D(p.get("pickup_charge", 0))), dropoff_charge=float(D(p.get("dropoff_charge", 0))), pickup_status="pending", delivery_status="pending",
                     picked_up_at=None, delivered_at=None, notes=None, customer_instructions=p.get("customer_instructions"))
        key = f"booking:{b['id']}:created"
        self._notify(p["customer_id"], "service_booking", "Booking received", b["booking_number"], "service_booking", b["id"], key)
        self._notify(vp["user_id"], "service_booking", "New service booking", b["booking_number"], "service_booking", b["id"], key)
        self._notify_admins("service_booking", "New service request", b["booking_number"], "service_booking", b["id"], key)
        return {"booking_id": b["id"], "booking_number": b["booking_number"]}

    # ------------------------------------------------------------------ accept / reschedule
    def _confirm(self, b, date, start, end):
        vs = self.one("vendor_services", id=b["vendor_service_id"])
        cap = vs["max_bookings_per_slot"] if vs else 1
        taken = sum(1 for x in self.rows("service_bookings") if x["vendor_service_id"] == b["vendor_service_id"] and x["status"] == "accepted" and x["id"] != b["id"]
                    and str(x["confirmed_date"]) == str(date) and str(x["confirmed_slot_start"])[:5] == str(start)[:5])
        if taken >= cap:
            raise cm("slot_full", f"{date} {start}")
        b.update(confirmed_date=date, confirmed_slot_start=start, confirmed_slot_end=end)

    def accept_service_booking(self, p_booking, p_vendor, p_actor, p_date, p_start, p_end, p_note):
        b = self.one("service_bookings", id=p_booking)
        if not b or b["vendor_id"] != p_vendor:
            raise cm("not_found", "booking")
        if b["status"] != "pending":
            raise cm("invalid_transition", f"{b['status']}>accepted")
        self._confirm(b, p_date or b["preferred_date"], p_start or b["preferred_slot_start"], p_end or b["preferred_slot_end"])
        b.update(status="accepted", accepted_at=NOW)
        self._history(b, "pending", "accepted", p_actor, p_note)
        self._notify(b["customer_id"], "service_booking", "Booking accepted", b["booking_number"], "service_booking", b["id"], f"booking:{b['id']}:status:accepted")
        return {"booking_id": b["id"], "status": "accepted"}

    def reschedule_service_booking(self, p_booking, p_vendor, p_actor, p_role, p_date, p_start, p_end, p_note):
        b = self.one("service_bookings", id=p_booking)
        if not b or (p_vendor and b["vendor_id"] != p_vendor):
            raise cm("not_found", "booking")
        if b["status"] != "accepted":
            raise cm("invalid_transition", f"{b['status']}>reschedule")
        self._confirm(b, p_date, p_start, p_end)
        self._notify(b["customer_id"], "service_booking", "Appointment rescheduled", b["booking_number"], "service_booking", b["id"], f"booking:{b['id']}:rescheduled:{p_date}:{p_start}")
        return {"booking_id": b["id"]}

    # ------------------------------------------------------------------ status machine
    def transition_service_booking(self, p_booking, p_vendor, p_status, p_actor, p_role, p_note):
        b = self.one("service_bookings", id=p_booking)
        if not b or (p_vendor and b["vendor_id"] != p_vendor) or (p_role == "customer" and b["customer_id"] != p_actor):
            raise cm("not_found", "booking")
        s = b["status"]
        if p_status == "accepted":
            raise cm("use_accept")
        if p_status in ("rejected", "cancelled") and not (p_note or "").strip():
            raise cm("reason_required")
        if p_role == "customer":
            ok = p_status == "cancelled" and s in ("pending", "accepted")
        elif p_status == "rejected":
            ok = s == "pending"
        elif p_status == "cancelled":
            ok = s == "accepted" or (p_role == "admin" and s in ("pending", "picked_up", "in_service", "ready_for_delivery"))
        elif p_status == "picked_up":
            ok = s == "accepted" and b["needs_pickup_dropoff"]
        elif p_status == "in_service":
            ok = (s == "accepted" and not b["needs_pickup_dropoff"]) or s == "picked_up"
        elif p_status == "ready_for_delivery":
            ok = s == "in_service"
        elif p_status == "completed":
            ok = s == "ready_for_delivery"
        else:
            ok = False
        if not ok:
            raise cm("invalid_transition", f"{s}>{p_status}")
        b["status"] = p_status
        if p_status == "rejected":
            b["rejection_reason"] = p_note
        if p_status == "cancelled":
            b.update(cancellation_reason=p_note, cancelled_by=p_actor)
        if p_status == "completed":
            b.update(completed_at=NOW, completion_notes=(p_note or "").strip() or b["completion_notes"])
        if p_status in ("rejected", "cancelled"):
            b.update(confirmed_date=None, confirmed_slot_start=None, confirmed_slot_end=None)
        pr = self._pickup(b["id"])
        if pr:
            if p_status == "picked_up" and pr["pickup_status"] not in ("completed", "cancelled"):
                pr.update(pickup_status="completed", picked_up_at=NOW)
            elif p_status == "completed" and pr["delivery_status"] not in ("completed", "cancelled"):
                pr.update(delivery_status="completed", delivered_at=NOW)
            elif p_status in ("rejected", "cancelled"):
                if pr["pickup_status"] != "completed":
                    pr["pickup_status"] = "cancelled"
                if pr["delivery_status"] != "completed":
                    pr["delivery_status"] = "cancelled"
        self._history(b, s, p_status, p_actor, p_note)
        vp = self.one("vendor_profiles", id=b["vendor_id"])
        key = f"booking:{b['id']}:status:{p_status}"
        if p_status == "cancelled":
            if p_role != "customer":
                self._notify(b["customer_id"], "service_booking", "Booking cancelled", p_note, "service_booking", b["id"], key)
            if p_role != "vendor":
                self._notify(vp["user_id"], "service_booking", "Booking cancelled", p_note, "service_booking", b["id"], key)
            if p_role != "admin":
                self._notify_admins("service_booking", "Booking cancelled", p_note, "service_booking", b["id"], key)
        else:
            kind = "pickup_delivery" if p_status in ("picked_up", "completed") else "service_booking"
            self._notify(b["customer_id"], kind, p_status, b["booking_number"], "service_booking", b["id"], key)
        return {"booking_id": b["id"], "status": p_status}

    # ------------------------------------------------------------------ charges / notes / logistics
    def add_service_charge(self, p_booking, p_vendor, p_actor, p_role, p_amount, p_reason):
        b = self.one("service_bookings", id=p_booking)
        if not b or (p_vendor and b["vendor_id"] != p_vendor):
            raise cm("not_found", "booking")
        if b["status"] not in ("accepted", "picked_up", "in_service", "ready_for_delivery"):
            raise cm("charge_not_allowed", b["status"])
        amount = D(p_amount)
        if amount == 0:
            raise cm("invalid_amount")
        if not (p_reason or "").strip():
            raise cm("reason_required")
        new_final = D(b["final_price"] if b["final_price"] is not None else b["estimated_price"]) + amount
        if new_final < 0:
            raise cm("final_negative")
        c = self.new("service_charges", booking_id=b["id"], amount=float(amount), reason=p_reason, recorded_by=p_actor, recorded_role=p_role)
        b.update(final_price=float(new_final), price_change_reason=p_reason)
        self._notify(b["customer_id"], "service_booking", "Repair charge updated", p_reason, "service_booking", b["id"], f"booking:{b['id']}:charge:{c['id']}")
        return {"charge_id": c["id"], "estimated_price": b["estimated_price"], "final_price": float(new_final)}

    def add_service_note(self, p_booking, p_vendor, p_actor, p_role, p_note):
        b = self.one("service_bookings", id=p_booking)
        if not b or (p_vendor and b["vendor_id"] != p_vendor):
            raise cm("not_found", "booking")
        return self.new("service_booking_notes", booking_id=b["id"], author_id=p_actor, author_role=p_role, note=p_note)["id"]

    def set_service_logistics(self, p_request, p_vendor, p_actor, p_role, p):
        r = self.one("pickup_dropoff_requests", id=p_request)
        if not r:
            raise cm("not_found", "pickup_request")
        b = self.one("service_bookings", id=r["booking_id"])
        if p_vendor and b["vendor_id"] != p_vendor:
            raise cm("not_found", "pickup_request")
        if b["status"] in ("rejected", "cancelled", "completed") or (p_role == "vendor" and b["status"] == "pending"):
            raise cm("invalid_transition", f"booking_{b['status']}")
        new_p, new_d = p.get("pickup_status") or r["pickup_status"], p.get("delivery_status") or r["delivery_status"]
        pat = p["scheduled_pickup_at"] if "scheduled_pickup_at" in p else r["scheduled_pickup_at"]
        dat = p["scheduled_delivery_at"] if "scheduled_delivery_at" in p else r["scheduled_delivery_at"]
        for old, new, label in ((r["pickup_status"], new_p, "pickup"), (r["delivery_status"], new_d, "delivery")):
            if new != old:
                if new == "completed":
                    raise cm("use_booking_status", label)
                allowed = (old in ("pending", "scheduled") and new in ("scheduled", "failed", "cancelled")) or (old == "failed" and new in ("scheduled", "cancelled"))
                if not allowed:
                    raise cm("invalid_transition", f"{label}_{old}>{new}")
        if new_p == "scheduled" and not pat:
            raise cm("schedule_required", "pickup")
        if new_d == "scheduled" and not dat:
            raise cm("schedule_required", "delivery")
        old_p, old_d = r["pickup_status"], r["delivery_status"]
        r.update(pickup_status=new_p, delivery_status=new_d, scheduled_pickup_at=pat, scheduled_delivery_at=dat, notes=p["notes"] if "notes" in p else r["notes"])
        if new_p != old_p:
            self._notify(b["customer_id"], "pickup_delivery", f"Pickup {new_p}", b["booking_number"], "pickup_dropoff", r["id"], f"pickup:{r['id']}:{new_p}:{pat}")
        if new_d != old_d:
            self._notify(b["customer_id"], "pickup_delivery", f"Delivery {new_d}", b["booking_number"], "pickup_dropoff", r["id"], f"delivery:{r['id']}:{new_d}:{dat}")
        return {"request_id": r["id"], "pickup_status": new_p, "delivery_status": new_d}
