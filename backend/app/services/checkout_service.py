"""Checkout. The client sends CHOICES only (address, payment method, coupon code, optional seller); every amount is computed here
from database values and platform settings, then handed to the atomic SQL function public.place_order, which re-validates
products, prices and stock under row locks, reserves stock and writes order + vendor orders + items + payment in ONE transaction.

Multi-vendor policy (client decision pending) lives in `_select_lines` only:
  * checkout.multi_vendor_policy = allow_multi_vendor        -> the whole cart becomes one order with one vendor order per seller
  * anything else (unset / single_vendor_only)                -> a cart with several sellers is refused unless the request names a
                                                                  vendor_id (that seller's items are checked out, the rest stay in the cart)"""
import hashlib
import json
import logging
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from app.core.dependencies import CurrentUser
from app.core.exceptions import NotFoundError, conflict, service_unavailable, unprocessable
from app.core.money import allocate, q2
from app.integrations.payments.base import PaymentProvider, PaymentProviderNotConfigured
from app.repositories.address_repository import AddressRepository
from app.repositories.base import Row
from app.repositories.cart_repository import CartRepository
from app.repositories.commerce_config_repository import CommissionRepository, CouponRepository, SettingsStore
from app.repositories.order_gateway import OrderGateway
from app.repositories.order_repository import OrderRepository
from app.repositories.payment_repository import PaymentRepository
from app.repositories.product_image_repository import ProductImageRepository
from app.repositories.product_repository import ProductRepository
from app.schemas.checkout import CheckoutRequest
from app.services import _order_views as views
from app.services import _pricing as pricing
from app.services._shopping import availability
from app.services.checkout_settings import ALL_KEYS, CheckoutSettings, load_settings
from app.services.payment_service import PaymentService

logger = logging.getLogger(__name__)


class CheckoutService:
    def __init__(self, db, admin_db, provider: PaymentProvider):
        self.db, self.provider = db, provider
        self.orders = OrderRepository(db)
        self.payments = PaymentRepository(db)
        self.carts = CartRepository(db)
        self.products = ProductRepository(db)
        self.images = ProductImageRepository(db)
        self.addresses = AddressRepository(db)
        self.gateway = OrderGateway(admin_db)
        self.coupons = CouponRepository(admin_db)
        self.commission = CommissionRepository(admin_db)
        self.settings = SettingsStore(admin_db)
        self.admin_orders = OrderRepository(admin_db)
        self.payment_service = PaymentService(db, admin_db, provider)

    # ------------------------------------------------------------------------------------------------ public
    def checkout(self, user: CurrentUser, body: CheckoutRequest, idempotency_key: str) -> dict:
        request_hash = self._request_hash(body)
        existing = self.orders.find_by_idempotency_key(user.id, idempotency_key)
        if existing:
            return self._replay(user, existing, request_hash)

        cfg = load_settings(self.settings.get_many(ALL_KEYS))
        self._release_expired_reservations()
        self._check_payment_method(body, cfg)
        address = self._delivery_address(user, body)
        lines = self._select_lines(user, body, cfg)
        payload = self._build_payload(user, body, cfg, lines, address, idempotency_key, request_hash)

        result = self.gateway.place_order(payload)                    # atomic: validates, reserves stock, writes everything
        order = self.orders.find(result["order_id"], customer_id=user.id)
        payment = self.payments.find(result["payment_id"], customer_id=user.id)
        if result.get("replay"):                                      # lost a race with an identical request: same order
            return self._respond(user, order, payment, replay=True)

        client_payload = None
        if body.payment_method.value == "online":
            try:
                payment, client_payload = self.payment_service.initiate(payment, order, user.id)
            except Exception:
                # the provider could not start the payment: give the stock back instead of holding an unpayable order
                self.gateway.cancel_order(order["id"], None, "system", "Payment could not be started")
                raise
        return self._respond(user, order, payment, replay=False, client_payload=client_payload)

    # ------------------------------------------------------------------------------------------------ steps
    def _request_hash(self, body: CheckoutRequest) -> str:
        identity = {"address": str(body.delivery_address_id), "method": body.payment_method.value, "coupon": (body.coupon_code or "").upper(),
                    "vendor": str(body.vendor_id) if body.vendor_id else None, "note": body.customer_note or ""}
        return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()

    def _replay(self, user: CurrentUser, order: Row, request_hash: str) -> dict:
        if order.get("request_hash") != request_hash:
            raise conflict("idempotency_key_reuse", "This Idempotency-Key was already used for a different checkout request.")
        payments = self.payments.for_order(order["id"], customer_id=user.id)
        payment = next((p for p in reversed(payments) if p["status"] in ("pending", "processing")), payments[-1] if payments else None)
        payload = None
        if payment and payment["status"] == "processing" and payment.get("provider_order_id") and self.provider.is_configured():
            payload = self.provider.client_payload(provider_order_id=payment["provider_order_id"], amount=payment["amount"], currency=payment["currency"])
        return self._respond(user, order, payment, replay=True, client_payload=payload)

    def _release_expired_reservations(self) -> None:
        try:                                                           # housekeeping must never block a customer
            self.gateway.expire_unpaid_orders(25)
        except Exception:  # noqa: BLE001
            logger.warning("could not expire unpaid orders", exc_info=True)

    def _check_payment_method(self, body: CheckoutRequest, cfg: CheckoutSettings) -> None:
        if body.payment_method.value == "cod":
            if not cfg.cod_enabled:
                raise conflict("cod_not_available", "Cash on delivery is not available right now.")
            return
        if not cfg.online_enabled:
            raise conflict("online_payments_disabled", "Online payments are not available right now.")
        if not self.provider.is_configured():
            raise PaymentProviderNotConfigured()

    def _delivery_address(self, user: CurrentUser, body: CheckoutRequest) -> dict:
        row = self.addresses.find_for_user(str(body.delivery_address_id), user.id)
        if row is None:
            raise unprocessable("invalid_address", "Choose one of your saved delivery addresses.")
        if row["address_type"] not in ("delivery", "both"):
            raise unprocessable("invalid_address", "That address is saved for pickup only; choose a delivery address.")
        keys = ("recipient_name", "phone", "address_line1", "address_line2", "landmark", "city", "state", "postal_code", "country")
        return {k: row.get(k) for k in keys}

    def _select_lines(self, user: CurrentUser, body: CheckoutRequest, cfg: CheckoutSettings) -> list[dict]:
        cart = self.carts.find_for_user(user.id)
        items = self.carts.items(cart["id"]) if cart else []
        if not items:
            raise conflict("empty_cart", "Your cart is empty.")
        products = {p["id"]: p for p in self.products.find_many([i["product_id"] for i in items])}   # RLS: only publicly listed products
        wanted_vendor = str(body.vendor_id) if body.vendor_id else None
        lines, issues = [], []
        for item in items:
            p = products.get(item["product_id"])
            if p is None:
                if wanted_vendor is None:
                    issues.append({"product_id": item["product_id"], "code": "product_unavailable", "message": "This item is no longer available."})
                continue
            if wanted_vendor and p["vendor_id"] != wanted_vendor:
                continue
            status, available = availability(p, item["quantity"])
            if status != "ok":
                code = {"not_listed": "product_unavailable", "unavailable": "product_unavailable"}.get(status, status)
                issues.append({"product_id": p["id"], "name": p["name"], "code": code, "available_quantity": available,
                               "message": f"{p['name']}: {status.replace('_', ' ')}"})
                continue
            price, paid_before = q2(p["price"]), item.get("price_when_added")
            if paid_before is not None and q2(paid_before) != price and not body.accept_price_changes:
                issues.append({"product_id": p["id"], "name": p["name"], "code": "price_changed", "previous_price": float(q2(paid_before)),
                               "current_price": float(price), "message": f"{p['name']}: price changed"})
                continue
            lines.append({"product": p, "quantity": item["quantity"], "unit_price": price})
        if issues:
            codes = {i["code"] for i in issues}
            code = codes.pop() if len(codes) == 1 else "checkout_validation_failed"
            raise conflict(code, "Some items in your cart need attention before you can check out.", details=issues)
        if not lines:
            raise conflict("empty_cart", "There is nothing to check out for that seller.")
        vendors = {ln["product"]["vendor_id"] for ln in lines}
        if len(vendors) > 1 and not cfg.multi_vendor_allowed:
            names = self._vendor_names(sorted(vendors))
            details = [{"vendor_id": v, "business_name": names.get(v), "items": sum(1 for ln in lines if ln["product"]["vendor_id"] == v)} for v in sorted(vendors)]
            hint = ("Your cart has items from several sellers, and checking out several sellers at once is not enabled yet. "
                    "Check out one seller at a time by sending that seller's vendor_id.")
            raise conflict("multi_vendor_checkout_not_allowed", hint, details=details)
        return lines

    def _vendor_names(self, vendor_ids: list[str]) -> dict[str, str]:
        return self.orders.vendor_names(vendor_ids)

    def _coupon(self, user: CurrentUser, code: str, subtotal: Decimal) -> Row:
        coupon = self.coupons.find_by_code(code)
        if coupon is None:
            raise unprocessable("coupon_invalid", "That coupon code is not valid.", details=[{"reason": "not_found"}])
        uses = self.admin_orders.count_coupon_uses(user.id, coupon["id"])
        problem = pricing.coupon_problem(coupon, subtotal, uses)
        if problem:
            raise unprocessable("coupon_invalid", "That coupon cannot be used for this order.", details=[{"reason": problem}])
        return coupon

    def _build_payload(self, user, body, cfg, lines, address, key, request_hash) -> dict:
        by_vendor: dict[str, list[dict]] = {}
        for ln in lines:
            by_vendor.setdefault(ln["product"]["vendor_id"], []).append(ln)
        vendor_ids = list(by_vendor)
        names = self._vendor_names(vendor_ids)
        subtotals = [sum((ln["unit_price"] * ln["quantity"] for ln in by_vendor[v]), Decimal(0)) for v in vendor_ids]
        subtotal = sum(subtotals, Decimal(0))

        coupon = self._coupon(user, body.coupon_code, subtotal) if body.coupon_code else None
        discount = pricing.discount_amount(coupon, subtotal) if coupon else Decimal("0.00")
        discounts = allocate(discount, subtotals)
        deliveries = pricing.delivery_charges(cfg.delivery, subtotals)
        totals = [s + d - x for s, d, x in zip(subtotals, deliveries, discounts, strict=True)]
        total = sum(totals, Decimal(0))
        if total <= 0:
            raise unprocessable("invalid_total", "The order total must be greater than zero.")
        if body.expected_total is not None and q2(body.expected_total) != q2(total):
            raise conflict("price_changed", "The total changed since you last saw it. Please review it and confirm again.",
                           details=[{"expected_total": float(q2(body.expected_total)), "current_total": float(q2(total))}])

        rules = self.commission.active_product_rules()
        images = self._primary_images([ln["product"]["id"] for ln in lines])
        vendor_orders = []
        for vid, sub, dlv, dsc, tot in zip(vendor_ids, subtotals, deliveries, discounts, totals, strict=True):
            items, rule_ids, vendor_commission = [], set(), Decimal(0)
            for ln in by_vendor[vid]:
                p = ln["product"]
                rule = pricing.select_commission_rule(rules, vid, p["category_id"])
                if rule is None and cfg.missing_commission_policy == "block":
                    raise service_unavailable("commission_not_configured", "Checkout is temporarily unavailable: no commission rule applies to one of the items.")
                amount = pricing.commission_for_line(rule, ln["unit_price"], ln["quantity"]) if rule else Decimal("0.00")
                vendor_commission += amount
                rule_ids.add(rule["id"] if rule else None)
                items.append({"product_id": p["id"], "name": p["name"], "brand": p.get("brand"), "model": p.get("model"), "condition": p["condition"],
                              "image_path": images.get(p["id"]), "unit_price": str(ln["unit_price"]), "quantity": ln["quantity"],
                              "commission_rule_id": rule["id"] if rule else None, "commission_amount": str(amount)})
            vendor_orders.append({"vendor_id": vid, "vendor_name": names.get(vid), "subtotal": str(sub), "delivery_charge": str(dlv), "discount_amount": str(dsc),
                                  "total_amount": str(tot), "commission_amount": str(vendor_commission),
                                  "commission_rule_id": next(iter(rule_ids)) if len(rule_ids) == 1 else None, "items": items})

        online = body.payment_method.value == "online"
        return {
            "customer_id": user.id, "idempotency_key": key, "request_hash": request_hash, "payment_method": body.payment_method.value,
            "delivery_address_id": str(body.delivery_address_id), "delivery_address": address, "customer_note": body.customer_note,
            "coupon_id": coupon["id"] if coupon else None, "coupon_code": coupon["code"] if coupon else None,
            "subtotal": str(subtotal), "delivery_charge": str(sum(deliveries, Decimal(0))), "discount_amount": str(discount), "total_amount": str(total),
            "currency": self._currency(), "provider": self.provider.name if online else None,
            "payment_due_at": (datetime.now(timezone.utc) + timedelta(minutes=cfg.payment_window_minutes)).isoformat() if online else None,
            "vendor_orders": vendor_orders,
        }

    @staticmethod
    def _currency() -> str:
        from app.core.config import get_settings
        return get_settings().currency

    def _primary_images(self, product_ids: list[str]) -> dict[str, str]:
        out: dict[str, str] = {}
        for img in self.images.for_products(product_ids):
            if img["is_primary"] or img["product_id"] not in out:
                out[img["product_id"]] = img["storage_path"]
        return out

    def _respond(self, user: CurrentUser, order: Row | None, payment: Row | None, *, replay: bool, client_payload: dict | None = None) -> dict:
        if order is None or payment is None:
            raise NotFoundError("Order not found.")
        order = self.orders.find(order["id"], customer_id=user.id) or order
        return {"order": views.load_detail(self.orders, order), "payment": views.payment_out(self.payments.find(payment["id"], customer_id=user.id) or payment),
                "client_payload": client_payload, "replay": replay}



