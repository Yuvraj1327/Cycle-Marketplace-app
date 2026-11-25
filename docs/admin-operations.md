# Admin operations (Step 10) — modules, backend additions, status, gaps

The admin console (`apps/admin_web`) now covers the whole marketplace. Everything goes through **FastAPI**; the browser never touches the database. The only direct
Supabase call is the signed-in administrator's **image upload** to the public `banners` bucket (storage policy `banners_admin_write` allows admins only); the backend then
stores just the path. Authorization is decided by the backend on every request (`require_admin`), exactly as in Step 9.

## Pages (all behind the admin guard)

| Section | Pages |
|---|---|
| Main | `/` Overview, `/customers`, `/vendors` (Step 9, unchanged) |
| Marketplace | `/products`, `/products/:id`, `/categories`, `/featured-products`, `/banners` |
| Operations | `/orders` (+ tab `/orders/fulfilment`), `/orders/:id`, `/services`, `/service-categories`, `/service-bookings`, `/service-bookings/:id`, `/pickups` |
| Finance | `/payments`, `/payments/:id`, `/refunds`, `/commission`, `/settlements` |
| Communication | `/notifications`, `/announcements` |
| Reports | `/reports/sales`, `/reports/orders`, `/reports/vendors`, `/reports/customers`, `/reports/services`, `/reports/payments` (`/reports` → sales) |
| Settings | `/settings` (platform), `/settings/charges`, `/settings/coupons`, `/profile` (account settings) |

## Backend: what already existed and what was added

The product/category/banner, order/payment/refund/settlement/commission/settings, and service/booking/pickup/ticket admin APIs already existed (Steps 4–6) and are reused.
Added or extended for this step (all admin-only, all tested; request bodies reject unknown fields):

**New endpoints (15)**

| Endpoint | Why |
|---|---|
| `GET/POST /admin/coupons`, `GET/PUT /admin/coupons/{id}` | no coupon API existed (checkout only *read* coupons). No delete: deactivate. Code locks after first use; usage limit cannot drop below redemptions |
| `POST/GET /admin/announcements`, `GET /admin/notifications` | broadcast + history; notification records of every type |
| `GET /admin/reports/{kind}` | six read-only SQL aggregates (migration 19) |
| `GET /admin/vendor-orders` | flat fulfilment overview (the order list only had parent orders) |
| `GET /admin/audit-log` | read access to the existing `audit_log` (product moderation, commission, settings, coupons, announcements, orders…) |
| `GET /admin/payments/provider` | whether a provider is configured (never credentials) |
| `GET /admin/commission-rules/resolve` | which rule checkout would apply (same function checkout uses) |
| `PATCH /admin/services/{id}/status` | admin can deactivate a vendor service (reason required, vendor notified, audited) |
| `GET /admin/orders/{id}/timeline`, `GET /admin/service-bookings/{id}/timeline` | status history with who changed it |

**Extended (additive, backwards compatible)**: orders list (`date_from/date_to`, `sort`, `q` now also matches customer and seller), payments list (`q`, dates, + `order_number`, `customer_name`), refunds list (`q`, dates, + `order_number`), settlements list (dates, + `vendor_name`), products list (`in_stock`, `sort`) and **audit entries** for approve/reject/activate/deactivate/feature, services list (`is_available`), booking list (`q` matches customer and provider, + `service_category`), pickup list (`q`), commission rules (names, `scope`, `state`, **conflict refusal**: two active rules with the same scope and priority and overlapping dates → 409), category names are now **unique** (case-insensitive, per type; product and service categories).

**Migration 19**: see `docs/database-schema.md`. It also fixes a Step 9 defect found during this step: vendor-decision notifications used `related_type = 'vendor_application'`, which the original CHECK rejected on a real database (the in-memory test double does not enforce CHECKs, and the failure was swallowed by design, so approvals worked but the vendor was never notified).

## Status by module

Legend: **Done** = implemented, backend integrated, tested with the in-memory backend harness and (for SQL) real PostgreSQL. **External** = needs a real service that has not been exercised.

| Module | Status | Notes |
|---|---|---|
| Products & moderation | Done | list/search/filter/sort/detail, approve / reject (reason) / deactivate / activate, history. **Admins do not edit a vendor's listing content** (price, photos, stock); they moderate. Needs client confirmation if editing is wanted |
| Categories | Done | create/edit/activate/deactivate/delete-if-unused, image upload (External: Storage), duplicate names refused |
| Featured products | Done | add/remove, eligibility enforced by the backend. **No manual ordering**: the data model has none |
| Banners | Done / External | CRUD, up/down ordering (two updates), preview, schedule, https-link validation; image upload needs real Storage |
| Orders | Done | list/search/filters/sort/dates, detail with vendor orders shown separately, historical prices, payments, refunds, timeline, cancel order / cancel one vendor order with reason. Admins cannot mark anything delivered |
| Fulfilment | Done | read-only monitoring of vendor orders (no courier, no GPS) |
| Service categories | Done | same rules as product categories |
| Services | Done | list/filter/detail; deactivate with reason. **A vendor can re-activate their own service**; stopping a vendor altogether = suspend the vendor |
| Service bookings | Done | list/search/filters, detail (charges, notes, pickup, photos, history), reject (pending) / cancel (open) with reason, complaints triage. Vendor notes/charges are read-only |
| Pickup & drop-off | Done | separate pickup / return status; schedule, fail, cancel, notes. Completion stays the vendor's booking update. No assignment to a person (no rider concept exists) |
| Payments | Done / External | list/search/filters/detail/overview; record cash collected (the only way COD becomes successful); check with provider needs a configured provider |
| Refunds | Done / External | create (idempotency key, amount ≤ eligible), approve/reject/fail, manual record with external reference; **process through a provider needs a configured provider**: today the UI says so and shows the real status |
| Commission | Done | rules with scope names, rate, priority, validity, state; conflict refusal; "which rule applies"; history; recorded order commission never changes |
| Vendor settlements | Done | records and filters. **Marking paid is not in the UI** (the backend supports it); no transfer is ever initiated |
| Notifications & announcements | Done / External | broadcast to customers / vendors / specific people as **in-app** notifications, atomic, active accounts only, history with delivered/read counts. **Push (FCM) is Step 11** |
| Coupons | Done | create/edit/activate/deactivate, validation, states. Only a redemption **counter** exists (no per-redemption table). Service coupons are not supported (bookings take no payment) |
| Reports | Done | six reports, date filters, charts and tables, real zeros / empty states. Definitions are shown on each page |
| Platform settings | Done | only the 11 settings the backend defines; no invented settings (no store name / support contact / free-text fields) |

## Verification actually performed

| Check | Result |
|---|---|
| `tsc -b`, `npm run build` | clean; bundle 743 kB (207 kB gzip) — not code-split yet (Step 12) |
| `oxlint` | 0 errors, the same 2 warnings as Step 9 |
| `vitest` component/unit | 165 passed (67 from Step 9 + 98) |
| Contract tests, real FastAPI app over HTTP (in-memory DB) | 38 passed (17 Step 9 + 21 Step 10: real checkout → fulfilment → COD collection → settlement → refund; real booking → pickup coordination; announcements; coupons incl. redemption at checkout; settings; reports) |
| Backend `pytest` | 453 passed (427 before), including real-PostgreSQL tests of migration 19 (atomic announcement fan-out, targeting, read counts, reports vs the records, the `related_type` fix, no access for `authenticated`) |
| Customer app / Vendor app tests + `flutter analyze` | 65 / 68 passed, 0 issues (unchanged apps) |
| Production bundle scan | no service-role string or JWT |

**Not verified**: a real Supabase project (sign-in, token refresh, Storage uploads and the `banners_admin_write` policy from the browser), a real payment provider (provider checks / refunds), push delivery, and the pages in a real browser (layout and responsiveness reviewed in code and CSS only — no screenshots).

## Open points for the client

1. Should admins be able to **edit product listings** (not only moderate them)?
2. Should a deactivated service stay off even if the vendor re-activates it (needs a flag and a vendor-side rule)?
3. Do vendors need **manual featured ordering**, or is "most recent" enough?
4. **Revenue definition** for "sales": the reports use item value of vendor orders on the day they were delivered.
5. Which **payment provider**, and may the admin console mark settlements as paid (record only) — the backend supports it, the UI deliberately does not yet.
6. Multi-vendor checkout policy, who delivers, repair price changes / charge approval — still open (unchanged from earlier steps).
