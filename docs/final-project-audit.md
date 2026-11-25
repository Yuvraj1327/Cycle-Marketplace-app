# Final project audit (Step 12)

Written from the source and from tests run during Step 12 — not from earlier reports. Where something could not be exercised, it is listed under "Not verified" instead of being implied to work.

**Environments available:** the real FastAPI app with an in-memory database and test doubles for Supabase Auth / Storage / FCM / payment gateway (`backend/tests/dev_server.py`); a throwaway **real PostgreSQL** cluster running all 20 migrations; Google Chrome (admin console); the Android SDK (builds only). **Not available:** a live Supabase project, a Firebase project, a payment provider sandbox, a phone or emulator. PostgREST (the HTTP layer Supabase puts in front of PostgreSQL) was never run: a download of its binary to test the backend against real PostgREST + RLS was blocked by the sandbox, so the FastAPI → PostgREST request syntax is checked only against mocked transport (6 tests) and the schema is checked against recorded usage (5 tests).

## 1. Component status

| Component | Status | Basis |
|---|---|---|
| FastAPI backend (v0.11.0, 177 operations) | Complete for the approved scope | 529 tests pass; hostile-input sweep over every operation × 6 callers; N+1 guard; schema conformance |
| Database (20 migrations) | Complete for the approved scope | All 20 applied on real PostgreSQL; constraints, triggers, SQL functions, RLS and storage policies exercised there |
| Supabase Auth / Storage / PostgREST live | **Not verified** | no project |
| Customer app (Flutter) | Complete for the approved scope | 86 tests (47 unit/widget run standalone + 39 HTTP contract tests); analyze clean; debug and release APK + AAB build |
| Vendor app (Flutter) | Complete for the approved scope | 90 tests (56 unit/widget + 34 HTTP contract tests); analyze clean; debug and release APK + AAB build |
| Admin website (React) | Complete for the approved scope | 169 tests; `tsc` clean; lint 0 errors / 3 warnings; production build; rendered in a real Chrome |
| Push notifications (FCM) | Built, **never delivered** | needs a Firebase project |
| Online payments | Architecture built, **no provider chosen** | needs a client decision |

## 2. Implemented modules
Authentication & roles · profiles & addresses · vendor onboarding / approval · categories · products, images, inventory · search / filter / sort · cart · wishlist · checkout (multi-vendor-capable, single-vendor by default) · orders & vendor orders · payments (adapter, webhook, COD) · refunds · commissions & settlements (records) · service catalogue · service bookings · repair progress & additional charges · pickup / drop-off · notifications (in-app + push outbox) · device registration · support tickets · coupons · announcements · reports · platform settings · audit trail · admin console for all of the above. Detail: `docs/client-requirement-compliance.md`.

## 3. Incomplete or intentionally absent
* Online payment provider — none chosen; nothing registered; checkout offers COD only (when an admin enables it).
* Firebase project — none; push reports "not configured" and nothing is simulated.
* iOS (build and push) — not set up (Xcode incomplete on the development machine; no Apple account).
* Android release **signing** — no keystore exists. Release builds are produced but signed with the *debug* key unless `android/key.properties` is present (see §8 and `docs/deployment-guide.md`). Such a build must not be uploaded to Google Play.
* No automated payouts, rider app, live tracking, chat, loyalty, referrals (out of scope by the brief).
* Support contact details are not stored on the server (taken from build-time values).
* Rate limiting is not implemented in the application (recommended at the reverse proxy / API gateway).

## 4. Broken functionality
**No open P0 or P1 defect is known.** Within what could be exercised, no checkout, order, booking, approval, payment-webhook or authorization failure remained after the fixes in §9. This statement is bounded by §1: nothing was run against live Supabase, a device or a gateway.

## 5. API integration gaps
* Static comparison of every call in the three clients with the OpenAPI document: customer 52, vendor 50, admin 75 calls — all exist with the same method and path; no client calls another role's area; no `/__dev` path or hard-coded production host in any client. (`docs/api-integration-map.md`.)
* Online payment checkout SDK and provider adapter — missing until a provider is chosen.
* FCM live delivery — never exercised.
* `POST /admin/refunds/{id}/actions` with `process` asks a **real provider** to refund; without one only the `manual` path (record a refund paid elsewhere) works.

## 6. Database issues
* Found by the real-PostgreSQL tests and fixed in earlier steps' migrations: notification `related_type` CHECK rejected vendor-decision notifications (migration 19); `service-images` write policy let any signed-in role write (migration 20); trigger functions callable by clients (revoked in migration 20).
* Reviewed and left as is: 16 foreign-key columns of audit / history tables carry no index on purpose (they are written often and read rarely; indexing them would only slow writes).
* Table-level privileges for `anon` remain in place from Supabase defaults and RLS is what protects the rows. Revoking them is a defence-in-depth recommendation, not a fix required for correctness.
* Historical records are preserved: no migration drops data tables; orders, payments, refunds, bookings use status columns and snapshot prices.

## 7. Authentication issues
* Tokens are verified for signature, expiry, issuer and audience (JWKS or legacy HS256); roles come only from `public.profiles`; forged `user_metadata` / `app_metadata` roles are ignored (tests).
* Deactivated or restricted accounts are refused immediately; but a **JWT that was already issued stays valid until it expires** (stateless tokens) — documented since Step 2.
* Real Supabase flows (sign-up confirmation e-mail, reset, refresh, phone OTP) are untested.

## 8. Security review (Step 12)
| Area | Result |
|---|---|
| Privilege escalation | A user cannot make themselves admin, change another user's profile / orders / addresses / notifications, read another vendor's records, or write to others' storage folders — tested **on real PostgreSQL** as the `authenticated` role (`test_users_cannot_escalate_or_read_each_others_records_in_the_database`). |
| Authorization over HTTP | Each of the 177 operations was called as anonymous, garbage-token, customer, vendor, suspended vendor and admin: no 5xx; unauthorised callers always receive 401/403/404 (`test_robustness_sweep.py`). |
| Injection | Search strings are escaped for PostgREST filters (35 tests); no string-built SQL in the application; SQL functions use parameters. |
| Secrets | Repository-wide scan (tracked and untracked files): no private key, service-account JSON, JWT, Google API key or provider secret in source. The only pattern hits are *test assertions* and a key generated at run time. Only the two `.env.example` files are tracked; `.env*`, `dart_defines.*.json`, `google-services.json`, `GoogleService-Info.plist`, `*.jks`, `*.keystore`, `key.properties` are ignored. The admin production bundle and the two release APKs (this step) and two debug APKs (Step 11) contain no service-role / private-key / `__dev` / API-key patterns. **No credential needs rotation based on this scan.** If a real key was ever pasted into a chat, a ticket or a shared drive, rotate it. |
| Webhooks | Signature checked over the raw body; amount / currency mismatch flagged and not confirmed; duplicates idempotent (14 tests). |
| Error responses | Uniform `{"error":{code,message}}`; validation errors never echo submitted values; unexpected errors return a generic message and are logged server-side. |
| CORS | Only configured origins (tested); wildcard documented as forbidden. |
| API documentation exposure | **Fixed in Step 12:** with `APP_ENV=production` the interactive docs and the OpenAPI document are off (`/docs`, `/redoc`, `/openapi.json` return 404) — test added. |
| Rate limiting | Not in the application. Put it at the reverse proxy / gateway (login, `/payments/webhook`, support tickets, image registration). |
| Residual | Lock-screen push text can show order numbers / refund amounts (shorten wording if wanted); a phone that was offline at sign-out can receive the previous user's pushes until FCM reports its token invalid; banner files removed from the admin console may remain in Storage. |

## 9. Issues found in Step 12 and their disposition

| Sev. | Issue | Disposition |
|---|---|---|
| P2 | When Supabase / PostgREST was unreachable the API answered a vague 502 | **Fixed:** network failures map to 503 `service_unavailable` with a clear message; the in-process error handler is covered by a test with the transport raising |
| P1 | **Admin sign-out did not end the browser session when Supabase could not be reached** (found by the real-browser run: after "Sign out" the login page appeared, but the stored session remained and a reload signed the administrator back in — dangerous on a shared computer) | **Fixed:** the gateway always finishes with a local sign-out (which removes the session before any network call); 2 regression tests; re-verified in Chrome (stored session gone, protected route closed) |
| P2 | Customer and vendor apps: when the server could not revoke the session during sign-out, the exception stopped the app from switching to the signed-out state although the device session was already gone | **Fixed** in both `AuthController`s (the failed revoke is ignored; `sessionExpired` no longer leaves an unhandled error); regression test in each app (fails without the fix) |
| P2 | Android release builds were silently signed with the debug key | **Fixed:** the build reads `android/key.properties` when present, otherwise falls back to debug and says so; no keystore invented. **Signing is still pending for the client** |
| P2 | Admin console shipped one 746 kB script | **Fixed:** route-level lazy loading; entry script now 570 kB (≈165 kB gzip) in 42 chunks; no behavioural change |
| P3 | API docs / OpenAPI exposed in production | **Fixed** (above) |
| P3 | Admin date filters rendered unstyled; metric cards filled the whole screen on a phone | **Fixed** in `index.css` (verified in Chrome) |
| P3 | A test asserted `eq.true` exactly; the newer `postgrest` library (2.30.1) sends `eq.True` | **Test fixed** (PostgreSQL's boolean input is case-insensitive). The dependency range `supabase>=2.10,<3.0` is open-ended — **pin exact versions in the deployment image** (see `docs/deployment-guide.md`) |
| — | Added: schema-conformance checks (every column / enum / RPC argument the code uses exists in the migrations), hostile-input sweep, N+1 guard, real-PostgreSQL RLS isolation test, 3 more storage-policy checks | Test coverage, not defects |
| Open (recommendation) | Hardening ideas not done: `/health/ready` database probe, rate limiting, revoking `anon` table grants | Documented; none blocks handover |

Earlier-step defects that Step 12 re-verified as fixed: `related_type` CHECK (migration 19), `service-images` policy and trigger-function exposure (migration 20), push token handling after sign-out.

## 10. Performance (measured)
Measured on a throwaway local PostgreSQL (laptop, not production hardware):
* 60,000 products: filtered catalogue page 21 ms, text search 57 ms with the existing indexes. No index was added.
* N+1 guard: commerce and service list endpoints make a constant number of database calls regardless of rows (`test_query_counts.py`).
* Admin: entry script 746 → 570 kB; routes load on demand; search boxes are debounced; tables are server-paginated.
* Mobile: lists are paginated; no excessive request loops found in the contract runs. Release APKs are 58 MB (customer 57.8, vendor 58.9) and AABs 46 MB — mostly Flutter / Firebase libraries. No on-device profiling was done.
* Not measured: behaviour under concurrent load, real network latency to Supabase.

## 11. External configuration required
Supabase project (URL, anon key, service-role key, JWT settings, migrations 01–20, admin created via `scripts/promote_admin`); Firebase project (four public values per app + a service-account key for the backend); payment provider (decision, key id / secret, webhook secret, adapter, checkout SDK); Android signing keystore; production domains for `CORS_ORIGINS` and `API_BASE_URL`; support e-mail / phone; Apple account for iOS. Step-by-step in `docs/deployment-guide.md`.

## 12. Testing still required before launch
1. Apply the migrations to a **staging Supabase** project and run the apps against it (sign-up e-mail, refresh, reset, Storage upload, signed URLs).
2. Run the real backend against PostgREST + RLS (the one test layer this environment could not reach).
3. Real-device run of both apps (navigation, camera/gallery, permissions, offline behaviour, push once Firebase exists).
4. Payment-provider sandbox: initiation, webhook signature, failure, delay, refund.
5. Load test the chosen host; confirm backup / restore of the database.
