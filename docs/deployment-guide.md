# Deployment guide

Nothing here has been run against a production or staging environment: no deployment, Play Store upload or live Supabase / Firebase / payment-gateway access happened during development. Treat every step as a checklist to be executed — and verified — in **staging first**. No secret appears in this document; placeholders look like `<this>`.

## 0. Order of work

1. Supabase project (staging) → 2. Backend → 3. Admin website → 4. Create the first admin → 5. Android apps → 6. Verify on staging (§9) → 7. Repeat for production with **separate** projects, keys and domains → 8. Firebase and payments when the client has them.

Use one Supabase project per environment. Never point a test build at production data.

## 1. Required accounts and credentials

| Needed | Used for | Who supplies |
|---|---|---|
| Supabase project (per environment) | Auth, PostgreSQL, Storage | client / platform team |
| Hosting for FastAPI (any host that runs Python 3.11+ and terminates HTTPS) | backend | client |
| Static hosting for the admin site (any host serving files with an SPA fallback) | admin console | client |
| Firebase project + Android apps registered (`com.cyclemarketplace.customer_app`, `com.cyclemarketplace.vendor_app`) | push notifications | client — optional until push is wanted |
| Apple developer account + APNs key | iOS push / iOS builds | client — not set up |
| Payment provider account (provider **not yet chosen**) | online payments | client decision |
| Android upload keystore | signing the release builds | client / developer — **never commit it** |
| Support e-mail and phone | shown in the apps | client |

## 2. Supabase

1. Create the project. Note the project URL, the **anon / publishable** key (public) and the **service-role** key (secret, backend only).
2. Apply `supabase/migrations/*.sql` **in file-name order (20 files)**: with the Supabase CLI (`supabase link` then `supabase db push`) or by pasting each file into the SQL editor. Migrations only add or alter; none drops a data table. **Take a backup before applying to any database that holds data.** Do not use `supabase db reset` outside a disposable development database.
3. Migration 09 creates the five Storage buckets (`avatars`, `shop-images`, `product-images`, `service-images`, `banners` — see `docs/storage-architecture.md`) and their policies. Confirm in the dashboard that `service-images` is **private** and the others are as documented.
4. Optional reference data: `supabase/seed/001_reference_categories.sql` (no prices, no users).
5. Auth settings: decide e-mail confirmation (recommended on), password rules, site URL / redirect URLs (admin origin), and phone OTP only if an SMS provider is configured. Use the new asymmetric JWT signing keys (the backend verifies via the JWKS URL); set `SUPABASE_JWT_SECRET` only if the project still uses the legacy shared secret.
6. Do not enable any client-side code path that uses the service-role key.

## 3. Backend (FastAPI)

**Runtime:** Python 3.11+, any ASGI host. Run behind HTTPS (reverse proxy or platform router).

```bash
cd backend
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt            # see "Pin the versions" below
uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2 --proxy-headers
```

**Pin the versions.** `requirements.txt` gives ranges (for example `supabase>=2.10,<3.0`). The suite was last run with: fastapi 0.115.5, starlette 0.41.3, uvicorn 0.32.1, pydantic 2.14.0, pydantic-settings 2.6.1, httpx 0.28.1, PyJWT 2.13.0, supabase 2.30.1 (supabase-auth / postgrest / storage3 2.30.1), email-validator 2.3.0. Freeze exactly what you test (`pip freeze > requirements.lock`) and install from that in production. A library upgrade once changed how booleans are encoded in query strings; the suite catches that class of change, so re-run it on every upgrade.

**Environment (production values; names as in `backend/.env.example`):**

| Variable | Production value |
|---|---|
| `APP_ENV` | `production` — also switches **off** `/docs`, `/redoc`, `/openapi.json` |
| `DEBUG` | `false` |
| `CORS_ORIGINS` | JSON list of the exact admin origin(s), e.g. `["https://admin.<domain>"]`; never `*` |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | from the project; keep the service-role key in the host's secret store |
| `SUPABASE_JWT_SECRET` | empty unless the project uses the legacy secret |
| `JWT_AUDIENCE` | `authenticated` |
| `BUSINESS_TIMEZONE` | `Asia/Kolkata` (or the client's zone) |
| `CURRENCY` | `INR` |
| `PAYMENT_PROVIDER`, `PAYMENT_PROVIDER_KEY_ID`, `PAYMENT_PROVIDER_KEY_SECRET`, `PAYMENT_WEBHOOK_SECRET` | empty until a provider is chosen (§8) |
| `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_FILE` **or** `FCM_SERVICE_ACCOUNT_JSON` | empty until Firebase exists (§7) |
| `PUSH_DISPATCH_INTERVAL_SECONDS` | `15` (0 = off; several workers are safe because rows are leased) |

**Checks after start:** `GET /health` → 200; `GET /health/config` → `{"supabase_configured": true}` (never shows values); `GET /docs` → 404 in production; a request with no token to a protected route → 401 in the standard error shape.

**Operations to arrange yourself:** log collection (the app logs to stdout; secrets and tokens are never logged); process supervision; HTTPS; **rate limiting** at the proxy (login-related traffic, `/payments/webhook`, `/support-tickets`, `/images`) — not implemented in the app; database backups (Supabase point-in-time recovery or scheduled dumps); an uptime probe on `/health` (liveness only — it does not test the database).

## 4. Admin website (React + Vite)

```bash
cd apps/admin_web
npm ci
# public values only, supplied by the build environment or a git-ignored .env.production:
#   VITE_API_BASE_URL=https://api.<domain>        (no /api/v1)
#   VITE_SUPABASE_URL=https://<project-ref>.supabase.co
#   VITE_SUPABASE_ANON_KEY=<anon / publishable key>
npm run typecheck && npm run lint && npm test && npm run build
```

Upload `dist/` to the static host. **SPA routing:** configure the host to answer every unknown path with `index.html` (otherwise a reload on `/orders` returns 404). Serve over HTTPS and add the origin to the backend's `CORS_ORIGINS` and to Supabase Auth's redirect URLs. Anything prefixed `VITE_` is public in the bundle — never put the service-role key, a payment secret or a Firebase service-account key there. Build the production bundle **without** test values (the last production build was checked for leftovers of the test configuration).

## 5. First administrator

There is deliberately no API to create admins.
1. The person signs up (or is invited) in Supabase Auth.
2. From `backend/`, with `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in the environment: `python -m scripts.promote_admin person@example.com`.
3. They sign in to the admin website. Before real use, in **Platform settings** set the values the client has decided (COD on/off, delivery charge, pickup/drop-off charges, multi-vendor policy, listing approval). None are seeded.

## 6. Android apps (Flutter)

Applications ids: `com.cyclemarketplace.customer_app`, `com.cyclemarketplace.vendor_app`. Permissions requested: `INTERNET`, `POST_NOTIFICATIONS`.

**Build-time configuration** is passed with `--dart-define` (compiled into the app; public values only). Copy `dart_defines.example.json` to `dart_defines.prod.json` (git-ignored) in each app and fill it in: `API_BASE_URL` (HTTPS, no `/api/v1`), `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPPORT_EMAIL`, `SUPPORT_PHONE`, `APP_VERSION`, optionally `PHONE_AUTH_ENABLED` (customer app, only if SMS OTP is configured) and the four `FIREBASE_*` values. **Always build releases with the production file** — a build without it falls back to the emulator address `http://10.0.2.2:8000`, which is useless (and blocked as cleartext) on a real phone.

**Signing.** No keystore exists in this repository. Create the upload keystore yourself, keep it outside git and back it up, then create `apps/<app>/android/key.properties` (git-ignored):

```
storeFile=<path to .jks, relative to the android/ folder or absolute>
storePassword=<password>
keyAlias=<alias>
keyPassword=<password>
```

With that file present the release build is signed with it. **Without it the release build is signed with the debug key — fine for local testing, rejected by Google Play.** Consider Play App Signing for the final key.

```bash
cd apps/customer_app    # and again in apps/vendor_app
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --release --dart-define-from-file=dart_defines.prod.json     # sideload / testing
flutter build appbundle --release --dart-define-from-file=dart_defines.prod.json   # Google Play
```

Bump `version:` in `pubspec.yaml` for every upload. Output: `build/app/outputs/flutter-apk/app-release.apk` and `build/app/outputs/bundle/release/app-release.aab`. Verified in this repository: both apps build release APK and AAB (APK ≈ 58 MB, AAB ≈ 46 MB) — debug-signed, because no keystore exists. **Not verified:** installing or running either app on a device or emulator. Do that on a real phone against staging before any store upload (Play Store listing, privacy policy and data-safety form are the client's to prepare). iOS is not configured.

## 7. Firebase / push notifications (optional until the client has a project)

1. Create a Firebase project; register two Android apps with the package names above; note `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID` for each app → put them in each app's `dart_defines.prod.json`. No `google-services.json` is used or should be committed.
2. Firebase console → Project settings → Service accounts → generate a private key → give it to the backend as `FCM_SERVICE_ACCOUNT_FILE` (path) or `FCM_SERVICE_ACCOUNT_JSON`, plus `FCM_PROJECT_ID`. Restart the backend; the admin console's notification page shows push as configured.
3. Verify on a real phone: sign in, accept the permission, place a test order from a second account, confirm the push arrives in background and tap opens the right screen; sign out and confirm the phone stops receiving. Until this is done, **do not describe push as working.**
4. iOS additionally needs an APNs key uploaded to Firebase and an Apple developer account.

## 8. Payments (provider not chosen)

Until a provider exists, leave `PAYMENT_PROVIDER*` empty: the customer app says online payment is unavailable and COD works if an admin enables it. When the client chooses a provider: obtain test (sandbox) credentials; implement a small `PaymentProvider` adapter in `backend/app/integrations/` (initiate, verify webhook signature over the raw body, refund) and the provider's checkout SDK behind the customer app's `PaymentLauncher`; register the webhook URL `https://api.<domain>/api/v1/payments/webhook` with the provider; set the four `PAYMENT_*` variables; run the provider's sandbox through: success, failure, delayed webhook, duplicate webhook, refund. The existing 14 payment tests use a clearly labelled test provider and prove the architecture only. **Do not enable live keys before the sandbox run passes, and do not create paid test orders in production.**

## 9. Staging acceptance checklist

- [ ] All 20 migrations applied; buckets and policies present; `service-images` private.
- [ ] Backend health OK; `/docs` closed with `APP_ENV=production`; CORS only the admin origin.
- [ ] Admin created; sign-in works; a customer / vendor account cannot open the admin site.
- [ ] Workflow A–G walked through by hand with three test accounts (vendor sign-up → admin approval → product → customer order → vendor fulfilment → admin view; booking with pickup/return; refund of a COD order with a manual refund record).
- [ ] Image uploads from a phone: product, shop, booking photo (check a customer cannot open another customer's booking image).
- [ ] Password-reset and sign-up e-mails arrive and their links land in the right place.
- [ ] Release APK installed on at least two phones; offline / airplane-mode behaviour reviewed.
- [ ] Database backup taken and a restore rehearsed.
- [ ] Secrets scan of the final artefacts; keys exchanged through a password manager, not chat.

## 10. Rollback and safety
Keep the previous backend image and admin `dist/`; roll back applications first, never the database. If a migration fails, fix forward with a new migration — do not drop tables or reset a database that holds data. Historical orders, payments, refunds and bookings must be preserved.
