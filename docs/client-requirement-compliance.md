# Client requirement compliance matrix (Step 12)

Every requirement in the Step 12 checklist, checked against the **actual source and tests**, not against the existence of a screen.

## How to read the statuses

| Status | Meaning here |
|---|---|
| **Fully implemented and tested** | Implemented end to end and covered by the automated evidence listed (see legend). It has **not** been run against a live Supabase project, a physical phone or a payment gateway: no such access existed. That limit applies to the whole project and is stated once here, not repeated on every row. |
| **Implemented but not fully tested** | Implemented, but the part that matters most needs a live service or device that was never available (live Supabase Auth, live Storage). |
| **Partially implemented** | Part of the requirement exists; the missing part is named. |
| **Not implemented** | Does not exist. |
| **Requires external configuration** | Code is present and tested with test doubles; it cannot work until the client supplies an account / credential (Firebase, payment provider, …). |
| **Requires client clarification** | A business rule is undecided; the current behaviour is a documented default. |

Evidence legend: **B** backend pytest (in-memory database + Python twins of the SQL functions) · **P** scenario on a **real PostgreSQL** cluster running all 20 migrations (constraints, triggers, SQL functions, RLS, storage policies) · **H** the app's own client code driven against the real FastAPI app over HTTP (dev harness: in-memory database, test doubles for Supabase Auth / Storage / FCM / payment gateway) · **W** widget / unit tests of the Flutter app or the admin console (vitest) · **S** static check (client vs OpenAPI, schema conformance, secrets) · **R** driven in a real Chrome against the production admin build + harness (admin only) · **X** never exercised (external).

Totals at the time of writing: backend 529 · customer app 86 (47 unit/widget tests run on their own + 39 HTTP contract tests that need the dev harness) · vendor app 90 (56 + 34) · admin console 169 (+ a 39-test contract suite against the harness) · all passing. See `docs/final-project-report.md` §E.

---

## A. Customer app

| # | Requirement | Status | Evidence / notes |
|---|---|---|---|
| 1 | Registration and login | Implemented but not fully tested | Client uses `supabase_flutter` (e-mail/password, optional phone OTP). Token verification, role-from-database, forged-claim rejection: B, P. The real Supabase sign-up / e-mail confirmation / reset flows were never run (X). |
| 2 | Session restore, refresh, expiry | Implemented but not fully tested | Refresh-once-on-401, expired → signed-out: W, H. Live token refresh against Supabase: X. |
| 3 | Customer profile management | Fully implemented and tested | B, H, W. |
| 4 | Multiple delivery addresses (+ default) | Fully implemented and tested | B (8), H, W. |
| 5 | Saved pickup / drop-off addresses | Fully implemented and tested | Same address book is used by service bookings; B, H. |
| 6 | Home screen and promotional banners | Fully implemented and tested | Active/scheduled banners only; B, H, W. Banner *images* are served from Storage (X, see row 29). |
| 7 | New bicycle marketplace | Fully implemented and tested | `product_type` filter; B, H, W. |
| 8 | Used bicycle marketplace | Fully implemented and tested | Listings come from approved vendors only. **Customers listing their own used cycles is not supported — client question** (`docs/database-schema.md`). |
| 9 | Spare-parts marketplace | Fully implemented and tested | B, H, W. |
| 10 | Accessories marketplace | Fully implemented and tested | B, H, W. |
| 11 | Product search | Fully implemented and tested | 35 injection/escaping tests, exact PostgREST request shapes (S); 60,000-product catalogue measured at 57 ms for a search on PostgreSQL (P). |
| 12 | Product filtering | Fully implemented and tested | Category tree, type, price, brand, condition, stock. B, H. |
| 13 | Product sorting | Fully implemented and tested | Stable keyset-free ordering with `id` tie-break. B. |
| 14 | Product details | Fully implemented and tested | B, H, W. |
| 15 | Wishlist | Fully implemented and tested | B (6), H, W. |
| 16 | Shopping cart | Fully implemented and tested | Quantity, stock, price-change flags; B (17), H, W. |
| 17 | Checkout | Fully implemented and tested | Server recalculates every amount; stock reserved atomically; idempotency key. B, P, H. |
| 18 | Payment method: Cash on delivery | Fully implemented and tested | Off until an admin enables it (`payments.cod_enabled`); order `confirmed`, payment `pending`, collected by an admin only after dispatch. B, H. |
| 19 | Payment method: online payment | **Requires external configuration** and **client clarification** | **No provider has been chosen** (deliberately). Architecture (adapter, signed webhook, idempotency, amount check, reconcile, refunds) is tested with a clearly labelled test provider (B, 14 tests). The customer app shows "online payment unavailable" via `UnavailablePaymentLauncher`. Nothing about a real gateway is verified. |
| 20 | Order history | Fully implemented and tested | B, H, W. |
| 21 | Order tracking | Fully implemented and tested | Status timeline from the history table; B, H. |
| 22 | Order cancellation where supported | Fully implemented and tested | Only while every vendor order is pending/accepted; stock restored; vendor notified (Step 11). B, P, H. |
| 23 | Service categories / browsing / details | Fully implemented and tested | B, H, W. |
| 24 | Service pricing | Fully implemented and tested | Price snapshot at booking; pickup/drop-off charges only if an admin set them (amounts unset — client). |
| 25 | Service date and time selection | Fully implemented and tested | Minimum notice, maximum advance, vendor opening hours, timezone Asia/Kolkata. **Slot capacity is not modelled** (client question). |
| 26 | Cycle issue description | Fully implemented and tested | B, H, W. |
| 27 | Cycle image upload | Implemented but not fully tested | Backend checks registered path, type and size by HEAD (test double); policies for `service-images` tested on real PostgreSQL (P). A real Storage upload from a phone: X. |
| 28 | Service booking, history, tracking | Fully implemented and tested | B (21), P, H, W; cross-app workflow D. |
| 29 | Doorstep pickup / drop-off + status | Fully implemented and tested | Logistics status kept separate from repair status; B, P, H; workflow E. No rider app / live tracking (out of scope by design). |
| 30 | Notifications (in-app list, unread badge, navigation) | Fully implemented and tested | B, P, H, W. |
| 31 | Notifications (push to the phone) | **Requires external configuration** | Device registration, outbox, dispatcher, FCM v1 adapter and deep-link routing are built and tested with a mocked transport (B, W). No Firebase project exists: **no push has ever been delivered to a device**. iOS not set up. |
| 32 | Support information | Partially implemented / **Requires client clarification** | Support tickets (create, list, detail; admins review and update status) are implemented (B, H); there is no in-ticket reply thread. The customer app has **no stored support e-mail/phone**: it shows the values given at build time (`SUPPORT_EMAIL`, `SUPPORT_PHONE`); the client must supply them. |
| 33 | Account management and logout | Fully implemented and tested | Logout also unregisters the push token (Step 11). Live Supabase sign-out: X. |

## B. Vendor app

| # | Requirement | Status | Evidence / notes |
|---|---|---|---|
| 1 | Vendor registration, login | Implemented but not fully tested | Same Supabase Auth caveat as customer rows 1–2. Self-service vendor sign-up (open vs invitation-only) is a **client decision**; it grants nothing until an admin approves. |
| 2 | Business profile, shop information | Fully implemented and tested | B, H, W. |
| 3 | Business images | Implemented but not fully tested | Upload path as customer row 27 (`shop-images` bucket policies: P). |
| 4 | Operating hours | Fully implemented and tested | Per-day open/close/closed editor; used by booking validation. B, H, W. |
| 5 | Service area, pickup availability | Fully implemented and tested | Postal codes, radius, pickup flag. B, H, W. |
| 6 | Vendor verification status (pending / approved / rejected / suspended) | Fully implemented and tested | Restrictions enforced by backend and RLS; workflow A. B, P, H. A rejected vendor cannot re-submit on their own (admin re-approves) — **client decision**. |
| 7 | Product creation (new cycles, used cycles, spare parts, accessories) | Fully implemented and tested | B (19), H, W. |
| 8 | Product image uploads | Implemented but not fully tested | As above (`product-images`). |
| 9 | Product editing, inventory, availability, deactivation | Fully implemented and tested | Stock updates are absolute (no delta endpoint); a simultaneous order can race a vendor's edit — documented in `docs/vendor-app.md`. Editing an approved listing does not reset approval — **client decision**. |
| 10 | Order listing, acceptance, rejection, fulfilment status, history | Fully implemented and tested | A vendor sees an order only after it is confirmed; stock/payment consistency. B (18), P, H, W; workflow C. |
| 11 | Service management, pricing, availability | Fully implemented and tested | B, H, W. |
| 12 | Service booking management: accept / reject / repair progress / service notes | Fully implemented and tested | B (24), P, H, W; workflow D. |
| 13 | Additional repair charges | **Requires client clarification** | Implemented (append-only charges, estimate never overwritten, customer notified) and tested; **whether customers must approve extra charges, and whether anything is collected, is undecided**. The app says "not confirmed by the customer". |
| 14 | Pickup and drop-off coordination | Fully implemented and tested | Scheduling, status updates, return delivery; B, H, W; workflow E. |
| 15 | Vendor dashboard | Fully implemented and tested | One-round-trip aggregate (`vendor_dashboard_summary`); P, B, H, W. |
| 16 | Sales revenue | Fully implemented and tested | Delivered-order totals from backend-computed snapshots. |
| 17 | Service revenue | Partially implemented | Shows the *recorded job value* of completed bookings. Services have no in-platform payment, commission or settlement (**client decision**). |
| 18 | Commissions, deductions | Fully implemented and tested | Snapshot at delivery: `net = gross − commission − processed refunds`. B, P. Rules for a missing commission rule (block vs zero) are configurable. |
| 19 | Settlement information, transaction history | Fully implemented and tested | Read-only settlement records and transactions. **No automated payout** (out of scope). Defaults — coupon discounts platform-funded, delivery charge retained by the platform — need client confirmation. |
| 20 | Notifications (in-app) | Fully implemented and tested | New order, cancellation, product approval/rejection (Step 11), booking events, announcements. |
| 21 | Notifications (push) | **Requires external configuration** | As customer row 31. |
| 22 | Account settings and logout | Fully implemented and tested | |

## C. Admin website

| # | Requirement | Status | Evidence / notes |
|---|---|---|---|
| 1 | Admin login, protected routes, non-admin rejection | Fully implemented and tested | Role read from `profiles`; customer/vendor tokens (even with forged claims) refused. W, B, P, R. Live Supabase sign-in: X → admin sign-in itself is *Implemented but not fully tested*. |
| 2 | Dashboard analytics | Fully implemented and tested | W, B, R (rendered in a real browser, no console errors). "Total platform sales" revenue-recognition rule: **client clarification**. |
| 3 | Customer management (list, search, filter, detail, activate/deactivate) | Fully implemented and tested | W, B, H, R. |
| 4 | Vendor management, approval / rejection, suspension / activation | Fully implemented and tested | W, B, P, H; approve flow also exercised in a real browser (R). |
| 5 | Product management, approval, deactivation | Fully implemented and tested | Approve verified in browser with confirmation dialog and stored result (R). Admins moderate; they do not edit listing content. |
| 6 | Product categories | Fully implemented and tested | Create validated in browser (R); delete only if unused. |
| 7 | Featured products | Fully implemented and tested | No manual ordering (data model has none). |
| 8 | Promotional banners | Implemented but not fully tested | CRUD, ordering, schedule tested; image upload needs real Storage (X). |
| 9 | Order management, delivery / fulfilment monitoring | Fully implemented and tested | W, B, H; admins cannot mark an order delivered. |
| 10 | Service categories, service provider management | Fully implemented and tested | W, B. |
| 11 | Service booking management, pickup / drop-off coordination | Fully implemented and tested | W, B, H. |
| 12 | Payment management, transaction records | Fully implemented and tested | Ledger and filters; COD collection by admin. Provider-side data: **Requires external configuration**. |
| 13 | Refund management | Fully implemented and tested (with a test provider) | Create → review actions → process, partial refunds, over-refund refused, idempotent; B (14 payment tests + admin flows), P. **No real provider refund has ever been issued.** |
| 14 | Commission management | Fully implemented and tested | Per-vendor/category rules, audit trail. B, W. |
| 15 | Vendor settlement information | Fully implemented and tested | Status transitions recorded; **no automated bank payouts** (out of scope). |
| 16 | Notifications | Fully implemented and tested (in-app) | Sent log with per-row push status; push delivery **Requires external configuration**. |
| 17 | Announcements | Fully implemented and tested | Confirmation dialog, recipients counted, stored; verified in a real browser (R). Does not claim push was sent. |
| 18 | Offers and coupons | Fully implemented and tested | Redeemed at **product** checkout only; coupons for services are not supported (bookings take no payment). Created in a real browser (R). |
| 19 | Reports | Fully implemented and tested | Orders, sales, vendors, customers, services, payments; backend-computed; B, W, R. |
| 20 | Platform settings | Fully implemented and tested | The 11 settings the backend defines; none invented. |
| 21 | Delivery charges | Fully implemented and tested; **amount requires client clarification** | Mechanism (flat/free-above, per order or vendor order) tested; no amount is seeded. |
| 22 | Pickup and drop-off charges | Fully implemented and tested; **amount requires client clarification** | `services.pickup_charge`, `services.dropoff_charge`; unset = 0. |
| 23 | Account management and logout | Fully implemented and tested | Sign-out confirmation and protected-route closure checked in a real browser (R). |

---

## Items that need the client (consolidated)

1. Payment provider (and its credentials); whether COD is on at launch; delivery / pickup / drop-off charge amounts; per order or per vendor order.
2. Multi-vendor cart (default today: one seller per checkout).
3. Whether customers may list their own used cycles.
4. Customer approval of additional repair charges; whether services are paid in-app.
5. Re-approval when an approved listing is edited; re-application after rejection; open vs invitation-only vendor sign-up.
6. Settlement policy (coupon funding, delivery-charge ownership, payout method), revenue-recognition rule for reports.
7. Slot capacity for services; who performs pickup/return.
8. Support e-mail / phone shown in the apps; Firebase project; Apple account (iOS).

## Not requested and not built (kept out of scope on purpose)
Separate delivery-boy app, live GPS tracking, customer–vendor chat, auctions, loyalty, referrals, subscriptions, automated bank payouts, unapproved payment providers.
