# Admin web (Step 9) — status, backend additions, known gaps

Code: `apps/admin_web/` (see its README for run/test commands). Scope of this step: foundation, authentication, dashboard, customers, vendors, profile.

## Backend additions made for this step

All admin-only (`require_admin`), run with the admin's own token (RLS `is_admin()` + guard triggers) except the read-only aggregates and the audit log,
which use the service-role client **after** authorisation. Nothing is ever deleted. Tests: `backend/tests/test_admin_users.py` (16) and a real-PostgreSQL scenario in `test_sql_integrity.py`.

| Endpoint | Purpose |
|---|---|
| `GET /admin/dashboard?from=&to=` | counts by status (customers, vendors by verification/account, orders, bookings), order values, per-day series (max 366 days, India time) |
| `GET /admin/customers`, `GET /admin/customers/{id}` | list (`q` name/e-mail/phone, `status`, `sort`, pagination, order/booking counts); detail with addresses + audit trail |
| `PATCH /admin/customers/{id}/status` | `active` / `inactive` / `restricted`; reason required unless activating; 409 when unchanged; audited |
| `GET /admin/vendors`, `GET /admin/vendors/{id}` | list (`q` incl. owner name/e-mail/phone, `business_type`, `verification_status`, `account_status`, `sort`); full application incl. shop-image URLs, review fields, audit trail |
| `POST /admin/vendors/{id}/approve | reject | suspend | reinstate` | pending/rejected→approved, pending→rejected (reason), approved→suspended (reason), suspended→approved. Compare-and-set: repeats/races answer 409 (`already_approved` …) and write nothing. The vendor gets an in-app notification. |
| `PATCH /admin/vendors/{id}/account-status` | the vendor's login account (`active`/`inactive`/`restricted`), separate from verification |

Migration `20260101000018_admin_console.sql`: read-only `admin_dashboard_summary(date, date)` and `admin_entity_counts(text, uuid[])` (service_role only). No table changes.
Existing admin endpoints reused as-is: `GET /admin/orders|service-bookings|products` (filterable by `customer_id` / `vendor_id`), `GET /admin/payments/summary`, `GET/PUT /profiles/me`, `GET /auth/me`.

## Security model

* Supabase Auth is the identity provider; the console sends the access token as a Bearer token, refreshes it once on a 401 and signs out when it cannot.
* On start-up and after every sign-in the console asks `GET /auth/me`; only `role = admin` and `status = active` opens the app. Customers/vendors/inactive admins are signed out with an explanatory message and **no admin API is called** for them. A backend 403 mid-session shows "Access denied".
* Every admin endpoint is protected by `require_admin` (anonymous 401, customer/vendor 403 — covered for all 11 new endpoints). Request bodies reject unknown fields, so `role` / verification fields cannot be injected (422).
* No service-role key or secret in the bundle (verified by a source scan test and by grepping the production build).
* No public admin sign-up; no endpoint can create or promote an admin (still done only with `scripts/promote_admin`).

## Verification actually performed

| Check | Result |
|---|---|
| `tsc -b` (TypeScript 7), `npm run build` | clean, bundle 597 kB (172 kB gzip) |
| `oxlint` | 0 errors, 2 warnings (React-compiler style hints in `useAsync` / `AuthProvider`) |
| `vitest` unit/component | 67 passed |
| Contract tests vs real FastAPI over HTTP (in-memory DB) | 17 passed |
| Backend `pytest` (incl. real PostgreSQL scenarios for migration 18) | 427 passed (402 before Steps 8–9: +25 this step and Step 8 combined) |
| Customer app tests/analyze; Vendor app tests/analyze | 65 + 68 passed, 0 issues |

**Not verified:** real Supabase sign-in/refresh/password change/reset e-mail, running in a real browser (layout/responsiveness verified by CSS review only, no screenshots), and Storage URLs of shop images (they are built from the configured Supabase URL).

## Known gaps / client decisions

* Customer/vendor **order and booking history** uses the existing admin list endpoints (latest 10, with the total shown); the full lists are under Orders and Service bookings (Step 10).
* Account status is enforced by the backend (inactive/restricted users get 403 `account_*`), but existing access tokens stay valid until they expire (stateless JWTs — documented limitation in `docs/backend-auth.md`).
* Vendor re-submission after rejection is still admin-driven (the vendor edits; an admin re-approves via "Approve after review").
* Vendor `account_status` filtering uses an id lookup (fine for thousands of vendors; a SQL view/join would be better at larger scale).
* "Total platform sales" is shown as order value by state plus the payments ledger (`collected`, `net`, commission); revenue recognition rules need client confirmation.
* The product, order, payment, refund, settlement, service, notification, report and settings modules were built in Step 10 — see `docs/admin-operations.md`.
