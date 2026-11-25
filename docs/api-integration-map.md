# API integration map (Step 11)

One backend contract (`/api/v1`, FastAPI OpenAPI at `/docs`) serves three clients. This file records **how each client integrates** and lists, per client, every endpoint it calls. The endpoint tables below are generated from the clients' source by the same scanner that `backend/tests/test_client_contracts.py` runs, so a call that is renamed or removed fails that test.

## Conventions (identical for every client)
| Topic | Contract |
|---|---|
| Authentication | `Authorization: Bearer <Supabase access token>`; FastAPI verifies signature, expiry, issuer and audience, then reads **role and status from `public.profiles`** (never from the token). One refresh + retry on a 401; still 401 → the app signs the user out. |
| Errors | `{"error": {"code", "message", "details?"}}`; 401 unauthenticated, 403 wrong role / inactive account / unapproved vendor, 404 also for records of other users, 409 business conflict, 422 validation (unknown fields are rejected). |
| Money | JSON numbers with 2 decimals; computed only by the backend (cart, checkout, commission, settlement, refund). Clients display, never compute authoritative totals. |
| Dates | ISO-8601 with offset (`timestamptz`); dates without time for booking days; platform day = Asia/Kolkata. |
| Pages | `{items, total, page, limit, pages}`; `limit` ≤ 100. |
| Status names | One set per entity, owned by the backend enums: order `pending/confirmed/completed/cancelled`; vendor order `pending/accepted/rejected/preparing/ready_for_dispatch/out_for_delivery/delivered/cancelled`; payment `pending/processing/successful/failed/cancelled/refunded/partially_refunded`; booking `pending/accepted/rejected/picked_up/in_service/ready_for_delivery/completed/cancelled`; logistics `pending/scheduled/completed/failed/cancelled`; refund `requested/approved/processed/rejected/failed`; settlement `pending/ready/paid/cancelled`; vendor verification `pending/approved/rejected/suspended`; push `pending/sending/sent/failed/skipped/expired`. |
| Idempotency | `Idempotency-Key` header on checkout and refund creation (payment attempts are de-duplicated by the one-open-attempt-per-order rule); repeating a key returns the original result. |

## Authentication flow
```
App (Supabase SDK) --e-mail/password--> Supabase Auth --> access token (JWT) + refresh token
App --Bearer--> FastAPI --verify (JWKS | HS256)--> GET /auth/me --> role, status, vendor verification (from the DB)
   Customer app: role must be customer & active   Vendor app: role vendor; onboarding / pending / approved / rejected / suspended routes
   Admin console: role admin & active, else signed out (no admin API is called)
401 -> refresh once -> still 401 -> sign out | 403 account_* -> show the reason
Sign-out: unregister push device (apps) -> POST /auth/logout (Supabase session revoked) -> discard session
```
Customers and vendors share one Supabase project and one `profiles` table; the app a person may use is decided by the role the **database** holds. A vendor sign-up requests `role=vendor` in sign-up metadata (the only role a user can request) and gets no business access until an admin approves the application. Admins are created only with `scripts/promote_admin`.

## Notification flow
```
business event (SQL function / trigger, inside the order/booking transaction)
  -> INSERT notifications (push_status='pending')            <- in-app notification exists only if the transaction committed
  -> dispatcher (worker every 15 s or admin "Send pending now"): claim (leased) -> FCM v1 send -> finish_push(sent | retry | failed | skipped)
  -> app: foreground banner + badge refresh | background/terminated: system notification -> tap -> routeForNotification -> screen
App <-> backend: GET /notifications, POST /notifications/{id}/read, POST /notifications/read-all, PUT /devices, POST /devices/unregister
Admin: POST /admin/announcements (fan-out), GET /admin/notifications, GET /admin/push/status, POST /admin/push/dispatch
```
Events (recipient): order placed (customer) / new order (vendor); payment received / failed (customer); order accepted · preparing · ready · out for delivery · delivered · completed (customer); part of an order rejected/cancelled (customer) and **cancelled by someone else (vendor)**; refund processed (customer); booking received (customer, vendor, admins); accepted · rescheduled · picked up · repair started · ready for delivery · completed · rejected · cancelled (customer; cancellation also vendor/admin); repair charge updated; pickup / return scheduled · failed · cancelled; vendor application decision (vendor); **product approved / rejected (vendor)**; admin announcements (customers / vendors / specific users).
Deep links: customer `order → /orders/:id`, `service_booking → /bookings/:id`; vendor `vendor_order → /orders/:id`, `service_booking → /bookings/:id`, `product → /products/:id`, `vendor_service → /services/:id`, `vendor_application → /status`; anything else → the notification list. Ids must be UUIDs; the screen loads the record through the backend, which answers 404 for records the user does not own.

## Payment flow (provider-neutral; no provider chosen)
```
Customer app -> POST /checkout (choices only; totals computed server-side)  [COD: order confirmed, vendor order released]
             -> POST /payments/create (online) -> PaymentProvider.create_payment -> client_payload -> PaymentLauncher (no SDK yet: "not available")
Provider -> POST /payments/webhook (public, signature verified over the RAW body, idempotent by event id, amount + currency checked)
          -> apply_payment_event (SQL): payment successful -> order confirmed -> vendor order released -> notifications
Admin -> collect-cod (only way COD becomes successful) | reconcile (asks the provider) | refunds: create -> approve -> process (provider or manual record)
```
Unconfigured: online payments report "not configured"; nothing is simulated. Secrets: `PAYMENT_PROVIDER_KEY_SECRET`, `PAYMENT_WEBHOOK_SECRET` exist only in the backend environment.

## Storage flow
Direct upload to Supabase Storage with the user's own session → register the path with the backend (ownership, existence, type, size checked) → public URL or backend-signed URL for display. Buckets and policies: `docs/storage-architecture.md`.

## Supabase services used
| Service | Customer app | Vendor app | Admin console | Backend |
|---|---|---|---|---|
| Auth (sign-in, session, refresh, reset e-mail) | yes | yes | yes | verifies tokens only; `POST /auth/logout` revokes a session |
| PostgreSQL | via FastAPI only | via FastAPI only | via FastAPI only | caller's token (RLS) or service role (after authorization) |
| Storage | uploads `service-images` | uploads `product-images`, `shop-images` | uploads `banners` | HEADs objects, signs private URLs |
| Realtime / Edge functions | not used | not used | not used | not used |

## Customer app → FastAPI (52 calls)
| Area | Calls |
|---|---|
| `/addresses` | `GET /addresses`, `POST /addresses`, `DELETE /addresses/{}`, `PUT /addresses/{}`, `PATCH /addresses/{}/default` |
| `/auth` | `POST /auth/logout`, `GET /auth/me` |
| `/banners` | `GET /banners` |
| `/cart` | `GET /cart`, `DELETE /cart/clear`, `POST /cart/items`, `DELETE /cart/items/{}`, `PUT /cart/items/{}` |
| `/categories` | `GET /categories` |
| `/checkout` | `POST /checkout`, `GET /checkout/options`, `POST /checkout/preview` |
| `/devices` | `PUT /devices`, `POST /devices/unregister` |
| `/notifications` | `GET /notifications`, `POST /notifications/read-all`, `POST /notifications/{}/read` |
| `/orders` | `GET /orders`, `GET /orders/{}`, `POST /orders/{}/cancel`, `GET /orders/{}/payment`, `GET /orders/{}/tracking` |
| `/payments` | `POST /payments/create`, `GET /payments/{}` |
| `/products` | `GET /products`, `GET /products/featured`, `GET /products/{}` |
| `/profiles` | `GET /profiles/me`, `PUT /profiles/me` |
| `/service-bookings` | `GET /service-bookings`, `POST /service-bookings`, `GET /service-bookings/options`, `GET /service-bookings/{}`, `POST /service-bookings/{}/cancel`, `POST /service-bookings/{}/images`, `DELETE /service-bookings/{}/images/{}`, `GET /service-bookings/{}/tracking` |
| `/service-categories` | `GET /service-categories` |
| `/services` | `GET /services`, `GET /services/{}`, `GET /services/{}/availability` |
| `/support-tickets` | `GET /support-tickets`, `POST /support-tickets`, `GET /support-tickets/{}` |
| `/wishlist` | `GET /wishlist`, `POST /wishlist/items`, `DELETE /wishlist/items/{}` |

## Vendor app → FastAPI (50 calls)
| Area | Calls |
|---|---|
| `/auth` | `POST /auth/logout`, `GET /auth/me` |
| `/categories` | `GET /categories` |
| `/devices` | `PUT /devices`, `POST /devices/unregister` |
| `/notifications` | `GET /notifications`, `POST /notifications/read-all`, `POST /notifications/{}/read` |
| `/service-categories` | `GET /service-categories` |
| `/vendor` | `GET /vendor/dashboard`, `GET /vendor/orders`, `GET /vendor/orders/{}`, `POST /vendor/orders/{}/accept`, `POST /vendor/orders/{}/reject`, `PATCH /vendor/orders/{}/status`, `GET /vendor/orders/{}/timeline`, `GET /vendor/pickup-requests`, `GET /vendor/pickup-requests/{}`, `PATCH /vendor/pickup-requests/{}`, `GET /vendor/products`, `POST /vendor/products`, `DELETE /vendor/products/{}`, `GET /vendor/products/{}`, `PATCH /vendor/products/{}`, `PUT /vendor/products/{}`, `GET /vendor/products/{}/images`, `POST /vendor/products/{}/images`, `PUT /vendor/products/{}/images/order`, `DELETE /vendor/products/{}/images/{}`, `PATCH /vendor/products/{}/images/{}`, `GET /vendor/service-bookings`, `GET /vendor/service-bookings/{}`, `POST /vendor/service-bookings/{}/accept`, `POST /vendor/service-bookings/{}/charges`, `POST /vendor/service-bookings/{}/notes`, `POST /vendor/service-bookings/{}/reject`, `PUT /vendor/service-bookings/{}/schedule`, `PATCH /vendor/service-bookings/{}/status`, `GET /vendor/service-bookings/{}/timeline`, `GET /vendor/services`, `POST /vendor/services`, `DELETE /vendor/services/{}`, `GET /vendor/services/{}`, `PATCH /vendor/services/{}`, `PUT /vendor/services/{}`, `GET /vendor/settlements` |
| `/vendors` | `GET /vendors/me`, `PUT /vendors/me`, `GET /vendors/me/status`, `POST /vendors/register` |

## Admin console → FastAPI (75 calls)
| Area | Calls |
|---|---|
| `/admin` | `GET /admin/announcements`, `POST /admin/announcements`, `GET /admin/audit-log`, `GET /admin/banners`, `POST /admin/banners`, `DELETE /admin/banners/{}`, `PUT /admin/banners/{}`, `GET /admin/categories`, `POST /admin/categories`, `DELETE /admin/categories/{}`, `PUT /admin/categories/{}`, `GET /admin/commission-rules`, `POST /admin/commission-rules`, `GET /admin/commission-rules/resolve`, `PUT /admin/commission-rules/{}`, `GET /admin/coupons`, `POST /admin/coupons`, `PUT /admin/coupons/{}`, `GET /admin/customers`, `GET /admin/customers/{}`, `PATCH /admin/customers/{}/status`, `GET /admin/dashboard`, `GET /admin/notifications`, `GET /admin/orders`, `GET /admin/orders/{}`, `PATCH /admin/orders/{}/status`, `GET /admin/orders/{}/timeline`, `GET /admin/payments`, `GET /admin/payments/provider`, `GET /admin/payments/summary`, `GET /admin/payments/{}`, `POST /admin/payments/{}/collect-cod`, `POST /admin/payments/{}/reconcile`, `GET /admin/pickup-requests`, `PATCH /admin/pickup-requests/{}/status`, `GET /admin/products`, `GET /admin/products/{}`, `PATCH /admin/products/{}/approval`, `PATCH /admin/products/{}/featured`, `PATCH /admin/products/{}/status`, `POST /admin/push/dispatch`, `GET /admin/push/status`, `GET /admin/refunds`, `POST /admin/refunds`, `GET /admin/refunds/{}`, `POST /admin/refunds/{}/actions`, `GET /admin/reports/{}`, `GET /admin/service-bookings`, `GET /admin/service-bookings/{}`, `PATCH /admin/service-bookings/{}/status`, `GET /admin/service-bookings/{}/timeline`, `GET /admin/service-categories`, `POST /admin/service-categories`, `DELETE /admin/service-categories/{}`, `PUT /admin/service-categories/{}`, `GET /admin/services`, `GET /admin/services/{}`, `PATCH /admin/services/{}/status`, `GET /admin/settings`, `PUT /admin/settings/{}`, `GET /admin/settlements`, `GET /admin/support-tickets`, `PATCH /admin/support-tickets/{}`, `GET /admin/vendor-orders`, `GET /admin/vendors`, `GET /admin/vendors/{}`, `PATCH /admin/vendors/{}/account-status`, `POST /admin/vendors/{}/approve`, `POST /admin/vendors/{}/reinstate`, `POST /admin/vendors/{}/reject`, `POST /admin/vendors/{}/suspend` |
| `/auth` | `POST /auth/logout`, `GET /auth/me` |
| `/profiles` | `GET /profiles/me`, `PUT /profiles/me` |

## Step 12 re-verification

* 177 operations in the OpenAPI document (58 shared/customer, 42 vendor, 77 admin). Every call made by the three clients (52 / 50 / 75) still maps to an operation (static test); the hostile-input sweep calls **every** operation as anonymous, with a garbage token, as customer, vendor, suspended vendor and admin and expects no 5xx and no accidental access.
* With `APP_ENV=production` the backend no longer serves `/docs`, `/redoc` or `/openapi.json`. The contract is still available offline: `python -c "import json; from app.main import app; print(json.dumps(app.openapi()))"` from `backend/`.
* Network failures between the backend and Supabase now surface as `503 service_unavailable` ("temporarily unreachable") instead of a vague 502; clients already treat 503 as retryable.
* Not verified: the FastAPI → PostgREST request syntax against a real PostgREST (checked only against a mocked transport and the recorded schema usage).
