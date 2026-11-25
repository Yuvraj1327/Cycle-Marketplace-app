# Cycle Marketplace — Vendor App (Flutter, Step 8)

Business app for bicycle shops, used-cycle sellers, spare-parts sellers and cycle-service providers. Identity is **Supabase Auth**; every business
action goes through the **FastAPI** backend with `Authorization: Bearer <Supabase access token>`. Images go straight to Supabase Storage with the
vendor's own session. The app never holds a service-role key, payment secret or any approval/role switch.

## Run

```bash
cd apps/vendor_app
flutter pub get
flutter run \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000 \        # FastAPI root (no /api/v1); 10.0.2.2 = host machine from the Android emulator
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon/publishable key> \ # public by design. NEVER the service-role key
  --dart-define=SUPPORT_EMAIL=help@example.com \           # optional
  --dart-define=SUPPORT_PHONE=+91...                       # optional
```

Without the Supabase values the app shows a configuration screen instead of crashing. Debug builds allow cleartext HTTP to a local backend; release
builds do not (use HTTPS). Backend prerequisites: migrations 01–17 applied; Storage buckets `product-images` and `shop-images` (migration 09).

## Flow

sign-up (`role: vendor` account) → business details (onboarding) → **pending** (waiting for an administrator) → **approved** → full app.
`rejected` vendors can correct details but cannot operate; `suspended` vendors are locked to a status screen. The app only *reads* the decision from
`GET /vendors/me`; nothing in the app can set it, and the backend refuses every business endpoint (403) for unapproved vendors.

Tabs: **Dashboard · Products · Orders · Services · Account**. Inventory, pickups, earnings, settlements, commissions, transactions, notifications,
business profile and settings are reached from those tabs / Account.

## Structure (`lib/`)

`app/` config, theme, router (`redirectFor` = the single access-rule function), shell · `core/api` the only HTTP code (Bearer token, one refresh+retry on
401, timeouts, `ApiException`) · `core/auth` identity + vendor-stage controller · `core/widgets` shared UI · `features/<name>/` models, repository,
providers, screens. State: Riverpod. Navigation: go_router. This is a separate Flutter package from the customer app; the generic API/pagination/widget
code was copied from it (not shared) so the customer app stays untouched.

## Tests

```bash
flutter analyze
flutter test                      # unit + widget tests (37)

# contract tests: real repositories + models over real HTTP against the real FastAPI app (in-memory DB, test payment provider, simulated Storage)
(cd ../../backend && .venv/bin/python -m tests.dev_server) &
CONTRACT_API=http://127.0.0.1:8791 flutter test test/contract     # 31 tests; stop the dev server afterwards
flutter build apk --debug
```

These do **not** exercise real Supabase Auth/Storage, a real payment gateway or a device UI. See `docs/vendor-app.md` for what is and is not verified.


## Push notifications (Firebase Cloud Messaging) — Step 11

Push is **off until the client's Firebase project values are supplied**; in-app notifications always work. Fill the four `FIREBASE_*` values in `dart_defines.<env>.json`
(copy `dart_defines.example.json`; Firebase console → Project settings → Your apps → Android) and run with `flutter run --dart-define-from-file=dart_defines.dev.json`.
No `google-services.json` is needed or committed: Firebase is initialised from those values. The server-side service-account key lives only on the backend.

What the app does (`lib/core/push/`): asks for the notification permission after sign-in, registers the FCM token with `PUT /devices`, re-registers when the token refreshes,
shows a banner (and refreshes the unread badge) for a push that arrives while the app is open, opens the right order / booking when a notification is tapped (after sign-in
if needed), and on sign-out calls `POST /devices/unregister` and invalidates the token on the device. Android only: iOS needs an Apple/APNs key in Firebase and was not set up.
Not verified against a live Firebase project (none exists yet): the app logic is tested with a fake push service; `firebase_push_service.dart` is only compiled and analysed.
