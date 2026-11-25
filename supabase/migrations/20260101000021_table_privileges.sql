-- Table privileges for the Supabase API roles.
--
-- Why this exists: PostgREST (the Supabase Data API) runs every request as `anon`, `authenticated` or `service_role`. Those roles need
-- table-level privileges BEFORE Row Level Security is even evaluated. Older Supabase projects granted them automatically on every new table in
-- `public`; newer projects do not ("Automatically expose new tables" off), so without this file every query fails with
--   42501 permission denied for table profiles   (the FastAPI backend then answers 403 on /api/v1/auth/me, even for a valid admin).
--
-- Security model is unchanged: every table below already has RLS enabled with explicit policies (migrations 000008, 000013, 000015, 000019,
-- 000020); a privilege only lets a request reach the policies, it never bypasses them. Idempotent: safe to run more than once.

grant usage on schema public to anon, authenticated, service_role;

-- backend / server side (bypasses RLS by design; the key never leaves the backend)
grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- signed-in users: read/write is decided by the RLS policies and guard triggers
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- anonymous visitors: read-only, and only on the tables that have an `anon` RLS policy (public catalogue data)
grant select on public.banners, public.categories, public.platform_settings, public.product_images, public.products,
                public.service_categories, public.vendor_services to anon;
grant select on public.vendor_public_profiles to anon, authenticated;       -- security-definer view (see migration 000002)
revoke insert, update, delete, truncate, references, trigger on public.vendor_public_profiles from anon, authenticated;

-- push tokens are only ever touched through the security-definer functions in migration 000020: never directly
revoke all on public.device_tokens from anon, authenticated;

-- Later migrations: only the server-side role gets automatic access. A new table must grant to `authenticated` / `anon` explicitly, so a table
-- can never be exposed to browsers and phones by accident (forgotten RLS).
alter default privileges in schema public grant all on tables    to service_role;
alter default privileges in schema public grant all on sequences to service_role;
