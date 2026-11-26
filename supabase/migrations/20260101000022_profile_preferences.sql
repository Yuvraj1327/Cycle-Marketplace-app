-- 22: per-account display preferences (theme, time zone, date format, currency), edited from the admin console's Account Settings.
-- Stored as a small JSON object on the caller's own profile row; the existing profiles_update_own policy already limits writes to the owner.
alter table public.profiles
  add column if not exists preferences jsonb not null default '{}'::jsonb;

do $$ begin
  alter table public.profiles add constraint profiles_preferences_is_object check (jsonb_typeof(preferences) = 'object');
exception when duplicate_object then null; end $$;
