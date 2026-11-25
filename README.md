# Cycle Marketplace

A multi-vendor marketplace connecting customers with bicycle shops, used-cycle sellers, spare-parts sellers and cycle servicing providers (including doorstep pickup/drop-off).

**Status (Step 12 — final QA, security and production-readiness pass):** the approved scope is built and tested with the real FastAPI app, real PostgreSQL and the clients' own test suites; it has **not** been run against live Supabase, a phone, Firebase or a payment provider. Read first: `docs/final-project-report.md` (status, QA evidence, remaining work, readiness per component), `docs/client-requirement-compliance.md` (every requirement with an honest status), `docs/final-project-audit.md` (findings and fixes), `docs/deployment-guide.md` (how to deploy). Supporting docs: `docs/integration-audit.md`, `docs/api-integration-map.md`, `docs/storage-architecture.md`, `docs/push-notifications.md`, `docs/admin-operations.md`, `docs/admin-web.md`, `docs/customer-app.md`, `docs/vendor-app.md`, `docs/service-booking.md`, `docs/orders-payments.md`, `docs/marketplace-api.md`, `docs/backend-auth.md`, `docs/database-schema.md`. Interactive API docs: `http://localhost:8000/docs` (development only: switched off when `APP_ENV=production`).

**Known pending items (external):** payment provider (not chosen), Firebase project (push), Android release signing keystore, a staging/production Supabase project, iOS. See the report.

## Technology Stack
- Customer & Vendor apps: Flutter / Dart
- Admin Panel: React + TypeScript + Vite
- Backend: Python + FastAPI
- Database/Auth/Storage: Supabase (PostgreSQL)

## Directory Structure
```
cycle-marketplace/
├── apps/
│   ├── customer_app/   # Flutter customer app
│   ├── vendor_app/     # Flutter vendor app
│   └── admin_web/      # React + Vite admin panel
├── backend/            # FastAPI (app/api/v1, core, schemas, models, services, repositories, integrations, tests)
├── supabase/           # migrations/, seed/
├── docs/
├── .gitignore
└── README.md
```

## Prerequisites
Flutter (with Dart), Python 3.11+, Node.js 20+ / npm, Supabase CLI (needed from the database step).

## Setup & Run
**Backend**
```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in your own values
uvicorn app.main:app --reload   # http://localhost:8000/health
pytest
```
**Customer App**
```bash
cd apps/customer_app && flutter pub get && flutter run
```
**Vendor App**
```bash
cd apps/vendor_app && flutter pub get && flutter run
```
**Admin Web**
```bash
cd apps/admin_web && cp .env.example .env && npm install && npm run dev   # http://localhost:5173
```
**Database** – apply `supabase/migrations/*` in order (`supabase db reset` locally, which also runs seed files if listed in `config.toml`), or run them in the SQL editor of a *development* project; optional reference data: `supabase/seed/001_reference_categories.sql`.

**Supabase** – install the CLI, then run `supabase init` inside this repo if `supabase/config.toml` is absent.

## Tests and builds
```bash
cd backend && pytest                                   # 529 tests (real-PostgreSQL scenarios need a local PostgreSQL install)
cd apps/admin_web && npm run typecheck && npm run lint && npm test && npm run build
cd apps/customer_app && dart format --set-exit-if-changed . && flutter analyze && flutter test            # same in apps/vendor_app
# HTTP contract tests (client code against the real FastAPI app with an in-memory database; NOT a real Supabase):
cd backend && python -m tests.dev_server &              # serves :8791
cd apps/customer_app && CONTRACT_API=http://127.0.0.1:8791 flutter test       # same for vendor_app
cd apps/admin_web && CONTRACT_API=http://127.0.0.1:8791 npm run test:contract
# Android: flutter build apk --release --dart-define-from-file=dart_defines.prod.json   (see docs/deployment-guide.md for signing)
```

## Secrets
The service-role key belongs only in `backend/.env`; never in Flutter or React code. Release signing keys (`*.jks`, `android/key.properties`), `dart_defines.*.json`, Firebase service-account files and every real `.env` are git-ignored.

Never commit real credentials. Only `.env.example` files with placeholders are tracked.
