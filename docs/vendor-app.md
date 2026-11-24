# Vendor app (Step 8) — status, backend additions, known gaps

Code: `apps/vendor_app/` (see its README for run/test commands).

## Backend additions made for this step (tested in `backend/tests/test_vendor_app_support_apis.py` and `test_sql_integrity.py`)

| Change | Why |
|---|---|
| **Migration `20260101000017_vendor_dashboard.sql`** — `vendor_dashboard_summary(vendor_id)` (read-only, `service_role` only) | one-round-trip aggregate for dashboard/earnings: order & booking counts by status, product counts, delivered-order sales + commission snapshots, completed-service value, settlement totals by status. No schema/table change. |
| `GET /vendor/dashboard` | exposes that function to the **approved** vendor only (vendor id comes from the session) |
| `GET /vendor/orders/{id}/timeline` | status history of the vendor's own order (RLS already allowed vendors to read it); other vendors → 404 |
| `GET /vendor/service-bookings/{id}/timeline` | status history of the vendor's own booking |
| `GET /vendor/products?product_type=&in_stock=` | server-side "New cycles / Used cycles / Spare parts / Accessories" and stock filters (the repository already supported them) |
| `GET /vendor/orders`, `GET /vendor/settlements` `?date_from=&date_to=` | server-side date range (inclusive calendar days, India time) |

Nothing existing was changed incompatibly; backend suite: 410 passed (402 before this step). Customer app: untouched, 65 tests still pass.

## Verification actually performed

| Check | Result |
|---|---|
| `dart format`, `flutter analyze` (vendor app) | 0 issues |
| `flutter test` (unit + widget, no server) | 37 passed |
| Contract tests vs the real FastAPI app over HTTP (in-memory DB) | 31 passed |
| `flutter build apk --debug` | built |
| Backend `pytest` (incl. real-PostgreSQL scenarios for migration 17) | 410 passed |
| Customer app `flutter test` + contract + analyze | 65 passed, 0 issues |

The contract tests found and fixed one real defect: scheduling a pickup did not move its stage to `scheduled` unless the status was sent with the time.
**Not verified** (needs external setup or a device): real Supabase sign-up/sign-in/reset, real Storage uploads (image upload calls are only exercised
through the fake `ImageStorage` and the simulated `/__dev/upload`), running the UI on an emulator/device, iOS, push notifications.

## Gaps, decisions needed from the client

* **Vendor sign-up uses `role: vendor` in Supabase sign-up metadata** (documented design in `docs/backend-auth.md`; a database trigger honours it). That grants *no* business access: only an administrator-approved vendor can use any business endpoint. Whether self-service vendor sign-up should be open or invitation-only is a client decision.
* **No re-submission for rejected vendors.** A rejected vendor can edit the application (`PUT /vendors/me`) but nothing flips it back to `pending`; an admin must re-review (Step 9 admin tools).
* **Additional repair charges have no customer-approval flow** in the backend. The app shows recorded charges as *not confirmed by the customer* and never claims approval. Services have no in-platform payment, commission or settlement; "service revenue" is the recorded job value only.
* **No notification for product approval/rejection** is written by the backend (vendors only see the status on the product), and the in-memory harness does not emit the vendor "new order" notification (the real SQL function does).
* **Payment references** (gateway ids) are not exposed to vendors by the backend; transactions show method/status/commission only.
* **Stock updates are absolute (`stock_quantity`)** — there is no vendor delta endpoint. The app applies the vendor's change relative to the freshest stock it just re-read, which narrows but does not eliminate the race with a simultaneous order.
* Settlement defaults (coupon discounts platform-funded; delivery charge retained by the platform) still need client confirmation; the order screen states this plainly.
* No per-vendor notification preferences exist in the backend (settings screen says so).
* Vendor-facing "operating hours" are required for customers to book services; the app warns when unset.
