# Cycle Marketplace — Customer App (Flutter, Step 7)

Material 3 customer app for the Cycle Marketplace. Identity is **Supabase Auth**; every business action goes through the **FastAPI** backend with
`Authorization: Bearer <Supabase access token>`. The app never holds a Supabase service-role key or any payment secret.

## Run

```bash
cd apps/customer_app
flutter pub get
flutter run \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000 \        # FastAPI root, no /api/v1. 10.0.2.2 = host machine from the Android emulator
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon/publishable key> \ # public by design. NEVER the service-role key
  --dart-define=SUPPORT_EMAIL=help@example.com \           # optional: shown on Support; hidden with an explanation while unset
  --dart-define=SUPPORT_PHONE=+91... \                     # optional
  --dart-define=PHONE_AUTH_ENABLED=false                   # true only if SMS OTP is configured in Supabase
```

Without `SUPABASE_URL`/`SUPABASE_ANON_KEY` the app shows a configuration screen instead of crashing. Debug builds allow cleartext HTTP (for a local
backend); release builds do not — use HTTPS.

Backend prerequisites: the Step 2 migrations applied, a `service-images` private bucket with the owner-folder policies from the schema docs, and a
customer account (self-registration creates role `customer`; the app never sends a role).

## Structure (`lib/`)

| Path | What |
|---|---|
| `app/` | config (`--dart-define`), theme, go_router (auth redirect, tabs shell), app widget |
| `core/api` | **the only HTTP code**: `ApiClient` (Bearer token, 1 refresh+retry on 401, timeouts, `ApiException` mapping) |
| `core/auth` | `AuthService` interface, Supabase implementation, `AuthController` (role/status come from `GET /auth/me`; non-customers are signed out) |
| `core/` | providers, `PagedController` (server-side pagination), shared widgets (loading/empty/error, cards, image) |
| `features/<name>/` | `models` (defensive JSON), `repository` (API calls), `providers`, `screens` |

State management: Riverpod. Navigation: go_router. HTTP: Dio. Images: cached_network_image / image_picker.

## Behaviour that matters

* **Totals are always the backend's.** Cart subtotal, delivery charge, discount and total come from `/cart`, `/checkout/preview` and `/checkout`. The app only displays them.
* **Checkout** uses `POST /checkout` with an `Idempotency-Key`. The key is reused for identical retries (network error/timeouts) and regenerated when address, method, coupon, seller or note changes. The cart is only reloaded/cleared after the backend answered successfully.
* **Payments.** COD is offered only if `/checkout/options` says it is enabled. Online payment is offered only if the backend reports a configured provider; no provider SDK is bundled (client has not chosen one), so `UnavailablePaymentLauncher` says so honestly. The app **never** marks anything as paid — status comes from the backend after its verified webhook.
* **Multi-vendor carts** follow the backend policy from `/checkout/options` (checkout one seller at a time when multi-vendor is not allowed).
* **Service booking**: slots come from `GET /services/{id}/availability`; photos go to the private `service-images` bucket at `<uid>/<bookingId>/<file>` and are then registered with `POST /service-bookings/{id}/images` (the backend verifies the object exists). Pickup/drop-off stages are shown separately from the repair status.
* Double-submit protection on login, checkout, booking, cancel, support and profile forms.

## Tests

```bash
flutter analyze
flutter test                               # unit + widget tests (30)

# contract tests: real repositories + models over real HTTP against the real FastAPI app on an in-memory DB with a TEST payment provider
(cd ../../backend && .venv/bin/python -m tests.dev_server) &
CONTRACT_API=http://127.0.0.1:8791 flutter test test/contract    # 35 tests; the dev server must be stopped afterwards
```

The contract tests do **not** exercise real Supabase Auth/Storage/PostgREST or a real payment gateway. See `docs/customer-app.md` for what is and is not verified.

```bash
flutter build apk --debug      # build/app/outputs/flutter-apk/app-debug.apk
```
