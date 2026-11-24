# Orders, checkout and payments (Step 5)

Interactive docs: `/docs`. Errors: `{"error": {"code", "message", "details?"}}`. Money = JSON number, 2 decimals; all arithmetic is `Decimal` on the server.

## Where the logic lives
| Concern | Where | Why |
|---|---|---|
| Who may do what, pricing, coupon, delivery, commission, multi-vendor policy | FastAPI services | business rules, easy to test and change |
| Anything that touches **stock, money or order status** | PL/pgSQL functions (migration 14), `service_role` only | one atomic transaction; PostgREST cannot do multi-statement transactions |
| Reads for customers/vendors/admins | the caller's own JWT (RLS) | database enforces isolation too |

`place_order`, `cancel_order`, `transition_vendor_order`, `apply_payment_event`, `attach_provider_order`, `new_payment_attempt`, `record_cod_collection`, `cm_create_refund`, `apply_refund_result`, `expire_unpaid_orders`, `platform_revenue`. API roles (`anon`, `authenticated`) cannot execute them. Lock order is always order -> vendor order -> payment -> refund (no deadlocks; verified by a concurrency test).

## Checkout (`POST /checkout`, header `Idempotency-Key` required)
The body holds **choices only** (`delivery_address_id`, `payment_method`, `coupon_code`, `customer_note`, `vendor_id`, `accept_price_changes`, optional `expected_total`). Amounts in the body are rejected (422). The server loads the cart, products (current price/stock), address, coupon, settings and commission rules, computes subtotal -> discount -> delivery -> total and a per-item commission snapshot, then calls `place_order`, which **re-validates under row locks** (active, approved, available, vendor approved, price equal, stock sufficient), reserves stock, writes order + vendor orders + items + payment, consumes the coupon and removes the purchased cart lines - or changes nothing.

Refused with a clear error: empty cart; unavailable/unapproved/inactive product; insufficient stock; cart price changed since added (confirm with `accept_price_changes`); `expected_total` differs; invalid/expired/used coupon; invalid address; COD disabled; online payments disabled or no provider; cart with several sellers (see below); no commission rule (see below).

**Idempotency:** same key + same body returns the same order (200, `replay: true`) even if the cart is empty by then; same key with a different body is 409 `idempotency_key_reuse`. Parallel duplicates are serialised by an advisory lock; verified with 8 simultaneous requests -> 1 order, stock deducted once.

## Stock model
Stock is **reserved (deducted) when the order is created** and returned exactly once (`order_items.stock_restored_at`) on cancellation, rejection, payment-window expiry or provider failure. Delivery does not touch stock again. Unpaid online orders hold stock for `checkout.payment_window_minutes` (default 30); a failed payment keeps the reservation for retry until then. `POST /admin/orders/expire-unpaid` (and a best-effort sweep inside checkout) cancels overdue ones. **A scheduler must call that endpoint (or `select expire_unpaid_orders()` via Supabase cron) every few minutes.**

## State machines
* **Vendor order:** `pending -> accepted -> preparing -> ready_for_dispatch -> out_for_delivery -> delivered` (`ready_for_dispatch -> delivered` allowed for pickup). `rejected` only from `pending` (reason required). `cancelled` before delivery (vendor: not once out for delivery; admin: any active). Anything else is 409 `invalid_transition` (enforced in SQL and by the existing trigger). Names map to the brief: preparing = processing, out_for_delivery = shipped, delivered = fulfilled.
* **Parent order:** `pending` (online, awaiting verified payment) -> `confirmed` (online paid, or COD at checkout) -> `completed` (every vendor order delivered or cancelled/rejected, at least one delivered) / `cancelled` (nothing left active). Derived, never set by hand except admin cancel.
* A vendor sees an order only once it is confirmed (`vendor_orders.released_at`).
* **Customer cancel:** only while every active vendor order is `pending`/`accepted`. **Admin cancel:** any active state, reason required, audited.
* Migration 13 **drops** the Step 2 policy that let vendors update `vendor_orders` straight through Supabase - that path would skip stock restoration and refunds.

## Multi-vendor (client decision pending)
Schema: one order -> many vendor orders -> many items. Behaviour is isolated in `CheckoutService._select_lines` and driven by setting `checkout.multi_vendor_policy`:
* `allow_multi_vendor` - the whole cart becomes one order; discount and delivery are split across vendor orders in whole cents (largest remainder, sums exactly).
* unset or `single_vendor_only` (default) - a cart with several sellers is refused with 409 `multi_vendor_checkout_not_allowed` listing the sellers; sending `vendor_id` checks out just that seller and leaves the rest in the cart. No ambiguous cross-vendor order is ever created.

## Payments
Statuses: pending, processing, successful, failed, cancelled, refunded, partially_refunded (order carries a mirrored `payment_status`). Only these can mark a payment **successful**: a **verified provider webhook** (or reconcile), or an **admin recording COD cash**. Vendors and customers cannot.
* One open attempt per order (unique index); `POST /payments/create` starts a retry or returns the open attempt.
* **Webhook** `POST /payments/webhook`: signature verified over the raw body by the adapter -> canonical events -> `apply_payment_event` (idempotent on `(provider, event_id)`). Amount or currency mismatch => flagged `needs_review`, **not** confirmed. Failure after success is ignored. Success after the order was cancelled, or a second payment for the same order => payment recorded, refund **requested**, flagged for review. Unknown references are acknowledged and stored as `unmatched`.
* **COD:** admin enables `payments.cod_enabled` (default off). Order is `confirmed` at checkout, payment `pending` (cash outstanding = `amount_due`). `POST /admin/payments/{id}/collect-cod` records collection, only once the order is out for delivery/delivered. A vendor rejecting part of a multi-vendor COD order reduces the cash due by that part.

### Payment provider: NOT YET CONFIGURED (needs client decision + credentials)
`app/integrations/payments/` defines the contract (`PaymentProvider`: `create_payment`, `client_payload`, `parse_webhook`, `refund`, `fetch_payment`). **No provider ships** and no code path simulates success: with `PAYMENT_PROVIDER` empty, online checkout, `/payments/create`, refunds-via-provider and the webhook return 503 `payment_provider_not_configured`. To go live, the client must tell us:
1. Which provider (e.g. Razorpay, Cashfree, PayU, Stripe) and which methods (UPI, cards, net banking, wallets).
2. A sandbox account, then production: **key id**, **key secret**, **webhook secret** (`PAYMENT_PROVIDER_KEY_ID`, `PAYMENT_PROVIDER_KEY_SECRET`, `PAYMENT_WEBHOOK_SECRET`; backend only).
3. The webhook URL registered in the provider dashboard: `https://<api-host>/api/v1/payments/webhook`, subscribed to payment success/failure and refund events.
4. Currency (default INR) and whether the provider supports partial refunds.
Then one adapter module implements the contract and calls `register_adapter("<name>", factory)`; nothing else changes. The mobile apps receive only `client_payload` (public ids).

## Refunds
Lifecycle `requested -> approved -> processed | failed | rejected` (`failed -> approved` to retry). Cancellation/rejection of a **paid** order only creates a `requested` refund - nothing is ever claimed as refunded until it is `processed`, which happens only via (a) the provider confirming (synchronously or by verified webhook) or (b) an admin recording a **manual** refund with the external payment reference. The database refuses refunds above `paid - already requested/processed` (row lock; verified with 4 parallel requests), and refunds are idempotent (`Idempotency-Key`). A processed refund updates `payments.refunded_amount`, the payment/order status and (for a delivered vendor order) the vendor's settlement deductions.

## Commission
Rules in `commission_rules` (admin CRUD, audited). Per item the most specific active rule wins (vendor-specific > category-specific > global, then `priority`). `percentage` = % of the line value; `fixed` = flat amount **per unit**, capped at the line value. The rule id and amount are snapshotted on the order item and summed on the vendor order, so later rate changes never alter past orders. **No rule matches -> `commission.missing_rule_policy`:** `block` (default: checkout returns 503 `commission_not_configured`) or `zero`. No rate is ever invented.

## Settlements (records only)
Created when a vendor order is `delivered`: `gross = subtotal`, `commission`, `deductions` (processed refunds), `net = gross - commission - deductions`. Status `pending` (payment not yet confirmed, e.g. COD cash) -> `ready` (payment confirmed) -> `paid` (an admin **records** a payout made outside the system, with its reference; compare-and-set so it cannot be overwritten). The platform initiates no transfers. Defaults that need client confirmation: coupon discounts are platform-funded (vendor keeps full `subtotal`) and delivery charges are retained by the platform.

## Audit
`audit_log` records COD collection, refund transitions, settlement payouts, setting and commission-rule changes, admin order actions and reconciliation (actor, action, entity, details). Order/vendor-order history keeps the real actor and note.

## Settings (`GET/PUT /admin/settings`)
`payments.cod_enabled` (off), `payments.online_enabled` (on), `checkout.multi_vendor_policy`, `checkout.delivery_charge` `{amount, free_above, per: order|vendor_order}` (none), `commission.missing_rule_policy` (block), `checkout.payment_window_minutes` (30), `marketplace.require_listing_approval` (on). Malformed values fall back to the safe default.

## Endpoints
Customer: `POST /checkout`, `GET /orders`, `GET /orders/{id}`, `GET /orders/{id}/tracking`, `POST /orders/{id}/cancel`, `GET /orders/{id}/payment`, `POST /payments/create`, `GET /payments/{id}`. Public (signature-authenticated): `POST /payments/webhook`.
Vendor (approved): `GET /vendor/orders`, `GET /vendor/orders/{id}`, `POST .../accept`, `POST .../reject`, `PATCH .../status`, `GET /vendor/settlements`.
Admin: `GET /admin/orders`, `GET /admin/orders/{id}`, `PATCH /admin/orders/{id}/status`, `POST /admin/orders/expire-unpaid`, `GET /admin/payments`, `GET /admin/payments/summary`, `GET /admin/payments/{id}`, `POST /admin/payments/{id}/collect-cod`, `POST /admin/payments/{id}/reconcile`, `GET/POST /admin/refunds`, `GET /admin/refunds/{id}`, `POST /admin/refunds/{id}/actions`, `GET /admin/settlements`, `POST /admin/settlements/{id}/mark-paid`, `GET /admin/settings`, `PUT /admin/settings/{key}`, `GET/POST /admin/commission-rules`, `PUT/DELETE /admin/commission-rules/{id}`.

## Open business decisions
Multi-vendor checkout; who funds discounts and who keeps delivery fees; fixed-commission semantics (per unit assumed); customer cancellation window (before preparation assumed); payment window length; whether vendors may cancel after accepting; payment provider and refund policy for partial returns; who physically delivers and collects COD cash (only admins record it today).
