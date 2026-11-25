# Customer app (Step 7) — status, backend additions, known gaps

Code: `apps/customer_app/` (see its README for run/test commands).

## Backend additions made for this step (all read-only, tested in `backend/tests/test_customer_app_support_apis.py`)

| Endpoint | Why |
|---|---|
| `GET /api/v1/checkout/options` | which payment methods are available (COD flag, online only if provider configured), multi-vendor policy, delivery rule — so the UI never offers what the backend would reject |
| `POST /api/v1/checkout/preview` | server-computed totals/coupon/per-seller split for the current cart, **writes nothing** (verified equal to a real checkout) |
| `GET /api/v1/service-bookings/options` | pickup/drop-off charges (or "not configured"), booking window |
| `GET /api/v1/notifications`, `POST /notifications/read-all`, `POST /notifications/{id}/read` | in-app notification list/badge (rows already written by earlier steps; own rows only) |

## Verification actually performed

| Check | Result |
|---|---|
| `dart format`, `flutter analyze` | 0 issues |
| `flutter test` (unit + widget) | 30 passed |
| Contract tests vs real FastAPI over HTTP (in-memory DB, locally-signed JWTs, test payment provider) | 35 passed |
| `flutter build apk --debug` | built (≈154 MB debug APK) |
| Backend `pytest` | 402 passed |

**Not verified** (needs external setup or a device): real Supabase Auth sign-in/sign-up/reset/phone OTP, real Supabase Storage uploads & signed URLs, a real payment gateway, push delivery to a phone (the code exists since Step 11; no Firebase project), on-device/emulator UI run & screenshots, iOS build. Step 12 added release APK / AAB builds (debug-signed: no keystore) — see `docs/final-project-report.md`.

## Known gaps / client decisions

* No payment provider chosen → online payment cannot complete; `UnavailablePaymentLauncher` reports this. Implement `PaymentLauncher` with the chosen SDK later.
* No API for: support contact details (taken from `--dart-define`), "recommended/popular" products, seller storefront page.
* Pickup/drop-off charges are `not configured` until an admin sets them (booking shows ₹0 with a notice; nothing is charged in-app).
* Business questions still open: multi-vendor cart policy, customer-listed used cycles, who delivers, repair price changes after booking.
