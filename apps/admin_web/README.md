# Cycle Marketplace — Admin Web (React + TypeScript + Vite, Step 9)

Administrator console. Identity is **Supabase Auth**; every business action goes through **FastAPI** with `Authorization: Bearer <access token>`.
Whether someone is an administrator is decided by the backend (`GET /auth/me` → `role = admin`, `status = active`) on every start-up and by every
admin endpoint (`require_admin`). Nothing in the browser (local storage, token claims, UI state) grants access. There is no public registration:
admin accounts are provisioned with `python -m scripts.promote_admin <email>` (see `docs/backend-auth.md`).

## Run

```bash
cd apps/admin_web
cp .env.example .env     # VITE_API_BASE_URL, VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY  (public values only)
npm install
npm run dev              # http://localhost:5173 (add this origin to the backend CORS_ORIGINS)
npm run build            # type-check (tsc -b) + production bundle
```

Without the Supabase values the app shows a configuration screen instead of crashing. **Never** put the service-role key in `.env`:
every `VITE_*` value is bundled into the browser (a test fails the build if a service-role string or JWT literal appears in the source).

## Structure (`src/`)

| Path | What |
|---|---|
| `app/` | config, router (`routes`), `AuthProvider` (backend-verified session), toasts |
| `services/api/` | `client.ts` the only HTTP code (Bearer token, one refresh+retry on 401, timeout, `ApiError`); `services.ts` typed Auth / Dashboard / Customer / Vendor / Profile services |
| `services/supabase/` | Supabase client + `AuthGateway` (sign-in, sign-out, refresh, reset e-mail, password change) |
| `components/` | `layout` (sidebar, top bar, breadcrumbs, page header), `common` (badges, metric cards, dialogs, modals, pagination, states), `tables`, `charts` (SVG) |
| `features/` | `authentication`, `dashboard`, `customers`, `vendors`, `profile`, `placeholders` |
| `hooks/`, `utils/`, `types/` | data/list hooks, formatting, API types mirroring the OpenAPI schemas |

## Pages

`/login`, `/forgot-password`, `/` (overview), `/customers`, `/customers/:id`, `/vendors` (all + pending applications), `/vendors/:id` (application review + decisions),
`/profile`. Products, Orders, Services & Bookings, Payments, Notifications, Reports and Settings are navigation placeholders (they call no APIs).

## Tests

```bash
npm run lint
npm test                                   # 67 unit/component tests (API client, auth + route protection, dashboard, customers, vendors, profile, secret scan)

# contract tests: the real services + client over real HTTP against the real FastAPI app (in-memory DB, locally signed JWTs)
(cd ../../backend && .venv/bin/python -m tests.dev_server) &
CONTRACT_API=http://127.0.0.1:8791 npm run test:contract     # 17 tests; stop the dev server afterwards
```

These do **not** exercise real Supabase Auth or a browser. See `docs/admin-web.md` for what is and is not verified.
