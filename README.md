# Cycle Marketplace

A multi-vendor marketplace connecting customers with bicycle shops, used-cycle sellers, spare-parts sellers and cycle servicing providers (including doorstep pickup/drop-off).

**Status:** Step 6 – cycle servicing bookings, repair workflow, doorstep pickup/drop-off, complaints. See `docs/service-booking.md`, `docs/orders-payments.md`, `docs/marketplace-api.md`, `docs/backend-auth.md`, `docs/database-schema.md`. API docs: `http://localhost:8000/docs`.

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

## Secrets
The service-role key belongs only in `backend/.env`; never in Flutter or React code.

Never commit real credentials. Only `.env.example` files with placeholders are tracked.
