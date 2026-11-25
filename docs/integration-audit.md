# Integration audit (Step 11)

Written from the actual source of Steps 1–10, not from earlier prompts. "Verified" says exactly how: **real PostgreSQL** (a throwaway cluster running every migration), the **in-memory backend harness** (the real FastAPI app with an in-memory database and test doubles for Supabase Auth / Storage / FCM / the payment gateway), **static check** (a test that reads the source), or **not verified**. No live Supabase project, Firebase project, Storage service or payment gateway was available at any point, so nothing below claims one was exercised.

## 1. Existing integrations (before Step 11) and what Step 11 changed

| Integration | State found | Step 11 |
|---|---|---|
| Supabase Auth in the 3 apps | Customer / vendor: `supabase_flutter` (e-mail + password, optional phone OTP). Admin: `@supabase/supabase-js`. Every call sends the access token as a Bearer token; FastAPI verifies signature, expiry, issuer, audience (JWKS or legacy HS256) and reads role/status from `public.profiles`. Refresh once on a 401 in all three clients; expired session → signed out. | Audited; cross-role tests added (below). No change needed. |
| Role provisioning | `handle_new_user` trigger creates the profile; only `vendor` may be requested at sign-up (documented design, grants nothing until approved); admin only via `scripts/promote_admin`. | Verified again by tests with forged `user_metadata` / `app_metadata` roles. |
| Supabase Postgres + RLS | 20 migrations (19 before this step). Customer/vendor/admin APIs use the caller's token (RLS applies); the service role is used only for audit rows, notifications, atomic SQL functions and read-only aggregates, always after authorization. | Migration 20 (below). |
| In-app notifications | `notifications` table + `/notifications` API, unread badge and list in both apps. Business events create rows inside the SQL functions that cause them (orders, payments, refunds, bookings, pickups). Admin announcements (Step 10). | Two missing events added (vendor told when someone else cancels their order; vendor told when a product is approved/rejected). Rows now double as the push outbox. |
| Push (FCM) | **None.** Step 10 said "Step 11". | Implemented — see §3. **Not verified live.** |
| Payment gateway | Provider-neutral adapter (`PaymentProvider`), signed-webhook endpoint, idempotent event application, reconcile, refunds, `UnavailablePaymentLauncher` in the customer app. **No provider chosen; no adapter registered.** | **Unchanged on purpose** (the brief forbids choosing a provider). Verified by 14 existing payment tests (§4). |
| Supabase Storage | 5 buckets + policies (migration 09). Customer app uploads booking photos to `service-images`; vendor app uploads product / shop images; admin console uploads banners / category images. Backend verifies each registered path (HEAD for type/size) before storing it. | Policies tested on real PostgreSQL; one tightening (customers only may write `service-images`). See `docs/storage-architecture.md`. |
| API contract | One FastAPI OpenAPI contract, `{"error":{code,message}}` errors, money as JSON numbers, `{items,total,page,limit,pages}` pages. | A static test now checks every call in the 3 clients exists in the backend (52 + 50 + 75 calls). See `docs/api-integration-map.md`. |
| Environment configuration | Backend `.env.example`; admin `.env.example`; Flutter `--dart-define` documented in READMEs. | `FCM_*` / `PUSH_*` added; `dart_defines.example.json` per Flutter app; `.gitignore` now blocks `.env*`, `dart_defines.*.json`, service-account JSON, `google-services.json`, `GoogleService-Info.plist`. |

## 2. Missing integrations and what is needed to complete them

| Missing | Why it is missing | Needed from the client / account |
|---|---|---|
| Live push delivery | No Firebase project | A Firebase project; Android app registered with the package names `com.cyclemarketplace.customer_app` and `com.cyclemarketplace.vendor_app`; the four public values (`FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`) per app; a **service-account key** for the backend (`FCM_SERVICE_ACCOUNT_FILE` or `_JSON`). iOS additionally needs an Apple developer account and an APNs key uploaded to Firebase (not done). |
| Online payments | No provider chosen | The provider decision, then its key id, key secret and webhook secret (`PAYMENT_PROVIDER*`), a webhook URL registered with the provider, and a small adapter implementing `PaymentProvider` + the provider's checkout SDK in `PaymentLauncher`. |
| Verification against real Supabase | No project available | A staging Supabase project with the 20 migrations applied, the `banners`/`shop-images`/… buckets created by migration 09, the JWT signing keys, e-mail confirmation settings, and an admin created with `scripts/promote_admin`. |
| iOS push / iOS builds | Xcode installation incomplete on the development machine; no Apple account | See above; not attempted. |
| Production CORS / URLs | No deployed environments | The real admin origin(s) for `CORS_ORIGINS` and the API base URL per environment. |
| Android release signing | No keystore | Step 12: release APK / AAB build for both apps; signing reads `android/key.properties` when it exists, otherwise the debug key is used (not uploadable). See `docs/deployment-guide.md` §6. |

## 3. Push notification design (what was built)

* **Database (migration 20)**: `device_tokens` (RLS on, **no policies and no table privileges for anon/authenticated**: a token can never be read or written from a client); `register_device_token` (one row per physical token; a phone that signs in as someone else *moves* the token; at most 10 active devices per user); `deactivate_device_token` (owner only); push outbox columns on `notifications`; `claim_pending_pushes` / `finish_push` (leased with `FOR UPDATE SKIP LOCKED`); `admin_push_status`; the `notifications` guard trigger now also forbids a user from changing the push columns of their own rows.
* **Why an outbox**: a notification row is written by the same transaction as the order / booking / payment it describes, so it exists only if that transaction committed; sending happens afterwards. If FCM is down, slow, misconfigured or absent, nothing about the order or booking changes: the row stays `pending` (retried with back-off 30 s → 1 h, 5 attempts) and ends `failed` / `expired` (older than 24 h) / `skipped` (no device or inactive account). The in-app notification is always there.
* **Backend**: `PushProvider` interface; `FcmProvider` (FCM HTTP v1; OAuth via a signed service-account JWT using PyJWT + httpx, no extra SDK; classifies `UNREGISTERED` / invalid tokens → deactivated, 429/5xx → retry, other 4xx → failed); `UnconfiguredPush` when no credentials (nothing simulated); `PushDispatcher`; an in-process worker (`PUSH_DISPATCH_INTERVAL_SECONDS`, default 15 s) that starts only when a provider is configured; admin endpoints `GET /admin/push/status` and `POST /admin/push/dispatch`; device endpoints `PUT /devices` and `POST /devices/unregister` (customer/vendor only; the `app` must match the account's role).
* **Payload**: the user's own notification title (≤ 100) and text (≤ 180) plus ids only (`notification_id`, `type`, `related_type`, `related_id`). No addresses, phone numbers, tokens or e-mail. The destination screen loads the record from the backend, which refuses records that are not the user's.
* **Flutter (both apps)**: `lib/core/push/` — `PushService` abstraction, `FirebasePushService` (initialised from `--dart-define`, no `google-services.json`), `PushController` (register after sign-in, re-register on token refresh, foreground banner + badge refresh, tap navigation with a pending route for signed-out taps, unregister on sign-out then delete the device token), `routeForNotification` (UUID-validated, per-app routes). Android: `POST_NOTIFICATIONS` permission, default channel `cycle_default` created natively. Token API note: firebase_messaging 17 deprecates `getToken`/`onTokenRefresh`/`deleteToken` in favour of `register()`/`onRegistered`, which yield a Firebase *installation id* for "direct send"; because FCM v1 acceptance of that id cannot be confirmed without a project, the documented registration-token calls were kept (see the comment in `firebase_push_service.dart`).

## 4. API integration status

* Backend 177 operations (58 shared/customer, 42 vendor, 77 admin) — `docs/api-integration-map.md`.
* **Static contract check (new)**: customer app 52 calls, vendor app 50, admin console 75 — every one exists in the backend with the same method and path shape; the apps do not call each other's API areas; no client contains a `/__dev` path or a hard-coded production host.
* **Client tests** (Step 12 recount): customer app 86 tests in total (47 unit/widget + 39 HTTP contract tests against the real FastAPI app with an in-memory DB), vendor app 90 (56 + 34), admin console 169 unit/component tests plus 39 HTTP contract tests — all pass.
* **Cross-application workflows** (`backend/tests/test_cross_app_workflows.py`, 6 tests): A+B vendor onboarding → approval → product → moderation → customer visibility; C+F order across the 3 apps with money consistency, notifications and push; cancellation; D+E service booking with pickup/return; one identity provider for three roles.

### Payment webhook / provider security (existing, re-verified)
`tests/test_payments.py` (14 tests): bad or missing signature changes nothing; webhooks need a configured provider; success confirms the order and releases the vendor order; duplicate callbacks are idempotent; amount or currency mismatch never marks paid; failed payments can be retried; late failure after success ignored; late payment after cancellation requests a refund; vendors and customers cannot mark payments paid; COD only by an admin and only once dispatched; reconcile applies provider truth through the same path. Secrets live only in the backend environment.

## 5. Cross-application gaps found and fixed

| Gap | Fix |
|---|---|
| Vendor not told when the customer or an admin cancels their order | Trigger `notify_vendor_order_cancelled` (not echoed for the vendor's own cancellation, not sent for orders never released to the vendor) |
| Vendor not told when a product is approved / rejected | Trigger `notify_product_moderation` (includes the reviewer's note on rejection) |
| Vendor-decision notifications violated a CHECK constraint on a real database | Fixed in migration 19 (Step 10) |
| Any signed-in role could write into its own folder of the private `service-images` bucket | Policy limited to customer accounts (migration 20) |
| Notifications could not reach phones | Push outbox + dispatcher + device registration |
| A signed-out phone would keep receiving the previous user's pushes | Token unregistered on sign-out and deleted on the device; reassigned if another account registers it; invalid tokens deactivated by the dispatcher |
| Clients and backend could drift silently | Static client-vs-OpenAPI test |

## 6. Security concerns (reviewed)

* **Secrets**: a repository-wide scan finds no private key, service-account JSON, JWT or Google API key in source, and none in the admin production bundle or the two debug APKs (service-role / FCM names absent). Tests assert configured FCM and payment secrets never appear in any API response, the OpenAPI document or the logs.
* **Authorization**: customer / vendor tokens never open admin endpoints even with forged role claims; roles come only from `public.profiles`; deactivated accounts lose access immediately (their still-valid JWT is refused) but `/auth/me` keeps answering so the app can explain.
* **CORS**: only the configured origins; disallowed origins receive no `Access-Control-Allow-Origin` (tested).
* **Known limitations**: (1) access tokens are stateless JWTs and stay valid until they expire after a sign-out or deactivation (documented since Step 2); (2) a push shows the notification text on the lock screen — refund amounts and order numbers can appear there; shorten the wording of sensitive notifications if the client prefers; (3) a signed-out phone that was **offline** at sign-out cannot call `/devices/unregister`; the device token is still deleted locally and the dispatcher deactivates the old token when FCM reports it invalid, but until then the previous user's pushes could reach that phone; (4) the in-process dispatcher assumes one or a few backend workers (leasing makes several safe); a managed scheduler calling `POST /admin/push/dispatch` is an alternative.

## 7. Not verified (stated plainly)

Live Firebase (token issuance, delivery, tap handling on a real device, background/terminated behaviour); iOS; a real payment provider; real Supabase Auth flows (sign-up e-mail confirmation, refresh, password reset e-mail), real Storage uploads / signed URLs / MIME enforcement; Android release builds; behaviour on physical devices and real networks; performance under load (a local 60,000-product measurement exists, see `docs/final-project-audit.md` §10; no load test).

## 8. Step 12 addendum

* Re-verified this step: role isolation on real PostgreSQL, the 177-operation hostile-input sweep, schema conformance, N+1 guard, production-docs switch (`APP_ENV=production`), secrets scan (clean), release builds.
* Found and fixed: admin sign-out left the browser session stored when Supabase was unreachable; customer / vendor sign-out did not complete its state change when the server-side revoke failed; backend→Supabase network failures returned a vague 502 (now 503 `service_unavailable`).
* Unchanged and still external: Firebase project, payment provider, live Supabase verification, iOS. Full list: `docs/final-project-report.md` §F.
