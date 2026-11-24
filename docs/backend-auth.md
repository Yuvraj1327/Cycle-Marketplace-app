# Backend authentication & authorization (Step 3)

## Flow
1. The client (Flutter / React) signs up or signs in **directly with Supabase Auth** (email or phone). FastAPI has no password endpoints and stores no passwords.
2. The client calls the API with `Authorization: Bearer <access_token>`.
3. FastAPI verifies the token itself (`app/core/security.py`): signature, `exp`, `iss` (`<SUPABASE_URL>/auth/v1`), `aud` (`authenticated`), required claims, and `role == authenticated` (anon/service tokens are refused).
   * Asymmetric keys (RS256/ES256/EdDSA): public key fetched from the project's JWKS endpoint and cached. No secret needed.
   * Legacy HS256: only if `SUPABASE_JWT_SECRET` is set. Algorithm is pinned per key family (no algorithm-confusion, no `alg: none`).
4. The application **role and status are read from `public.profiles`** (never from the token or the client).
5. Database access uses a client authenticated **as the user** (anon key + the user's JWT), so the Step 2 RLS policies and guard triggers still apply. The service-role key is not used by any request path.

## Dependencies (`app/core/dependencies.py`)
`get_current_user` (any status) -> `get_current_active_user` (status must be `active`) -> `require_role(...)`, `require_customer`, `require_vendor`, `require_admin`, and `require_approved_vendor` (vendor with `verification_status = approved`; used by later vendor features).

## Endpoints
| Method | Path | Access |
|---|---|---|
| GET | /health, /health/config | public |
| GET | /api/v1/auth/me | any authenticated user |
| POST | /api/v1/auth/logout?scope=local\|global\|others | any authenticated user (revokes the Supabase session) |
| GET / PUT | /api/v1/profiles/me | any user (PUT: active accounts) |
| POST / GET | /api/v1/addresses | customer |
| GET / PUT / DELETE | /api/v1/addresses/{id} | customer, owner only |
| PATCH | /api/v1/addresses/{id}/default | customer, owner only |
| POST | /api/v1/vendors/register | vendor role |
| GET / PUT | /api/v1/vendors/me | vendor role (PUT refused when suspended) |
| GET | /api/v1/vendors/me/status | vendor role |

Errors: `{"error": {"code", "message", "details?"}}`. 401 (`not_authenticated`, `invalid_token`, `token_expired`), 403 (`permission_denied`, `account_inactive|restricted`, `vendor_pending|rejected|suspended|not_registered`), 404, 409, 422, 503 (auth provider/config).

## Roles and how they are obtained
* `customer` - default. `vendor` - the person signs up with `role: vendor` in sign-up metadata (see decision 1 below); the role alone grants **no** vendor privileges until an admin approves the application. `admin` - never via sign-up or API.
* Provision an admin: the person signs up normally, then on a trusted machine with the service-role key in `backend/.env`: `python -m scripts.promote_admin person@example.com`.
* Role/verification/approval fields are not accepted by any request schema (422), and the database triggers from Step 2 reject them as well.

## Known limitations
* Access tokens are stateless: after `logout` the token still verifies until `exp`. Keep the Supabase JWT expiry short and have clients discard tokens.
* No admin endpoints exist yet, so vendor approval is currently done by an admin/service role directly in the database until the admin APIs are built.
* Not exercised against a live Supabase project (no credentials available).
