-- 02: profiles, addresses, vendor profiles, auth sync, auth helper functions

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null default '',
  email       text,
  phone       text,
  role        public.user_role      not null default 'customer',
  status      public.account_status not null default 'active',
  avatar_path text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint profiles_phone_format check (phone is null or phone ~ '^\+?[0-9]{7,15}$')
);
create unique index profiles_phone_key on public.profiles (phone) where phone is not null;
create unique index profiles_email_key on public.profiles (lower(email)) where email is not null;
create index profiles_role_status_idx on public.profiles (role, status);
create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

create table public.user_addresses (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete cascade,
  label          text,
  address_type   public.address_type not null default 'both',
  recipient_name text not null,
  phone          text not null,
  address_line1  text not null,
  address_line2  text,
  landmark       text,
  city           text not null,
  state          text not null,
  postal_code    text not null,
  country        text not null default 'India',
  is_default     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index user_addresses_user_idx on public.user_addresses (user_id);
create unique index user_addresses_one_default_idx on public.user_addresses (user_id) where is_default;
create trigger user_addresses_set_updated_at before update on public.user_addresses
  for each row execute function public.set_updated_at();

create table public.vendor_profiles (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null unique references public.profiles (id) on delete restrict,
  business_name            text not null,
  business_types           public.vendor_business_type[] not null,
  description              text,
  address_line1            text not null,
  address_line2            text,
  city                     text not null,
  state                    text not null,
  postal_code              text not null,
  contact_phone            text not null,
  contact_email            text,
  operating_hours          jsonb not null default '{}'::jsonb,
  shop_image_paths         text[] not null default '{}',
  service_area_postal_codes text[] not null default '{}',
  service_radius_km        numeric(6,2) check (service_radius_km is null or service_radius_km >= 0),
  pickup_available         boolean not null default false,
  -- admin-controlled review fields
  verification_status      public.vendor_verification_status not null default 'pending',
  reviewed_by              uuid references public.profiles (id) on delete set null,
  reviewed_at              timestamptz,
  review_notes             text,
  rejection_reason         text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  constraint vendor_business_types_not_empty check (cardinality(business_types) > 0)
);
create index vendor_profiles_status_idx on public.vendor_profiles (verification_status);
create index vendor_profiles_city_idx on public.vendor_profiles (city);
create trigger vendor_profiles_set_updated_at before update on public.vendor_profiles
  for each row execute function public.set_updated_at();

-- ---------- Authorization helpers (SECURITY DEFINER => bypass RLS, so policies cannot recurse) ----------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin' and status = 'active'
  );
$$;

create or replace function public.current_user_role()
returns public.user_role language sql stable security definer set search_path = ''
as $$
  select role from public.profiles where id = (select auth.uid());
$$;

create or replace function public.is_active_user()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles where id = (select auth.uid()) and status = 'active');
$$;

-- vendor_profiles.id of the signed-in user (any verification status), or null
create or replace function public.current_vendor_id()
returns uuid language sql stable security definer set search_path = ''
as $$
  select id from public.vendor_profiles where user_id = (select auth.uid());
$$;

-- true when the signed-in user is an approved vendor with an active account
create or replace function public.is_approved_vendor()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.vendor_profiles v
    join public.profiles p on p.id = v.user_id
    where v.user_id = (select auth.uid())
      and v.verification_status = 'approved' and p.status = 'active'
  );
$$;

-- true when the given vendor_profiles.id is approved and its account active (used for public visibility)
create or replace function public.vendor_is_approved(vendor uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.vendor_profiles v
    join public.profiles p on p.id = v.user_id
    where v.id = vendor and v.verification_status = 'approved' and p.status = 'active'
  );
$$;

-- ---------- Sync auth.users -> profiles ----------
-- Only 'customer' and 'vendor' may be requested at signup; anything else (incl. 'admin') becomes 'customer'.
-- Admins are promoted out-of-band with the service role / SQL editor.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  requested_role text := new.raw_user_meta_data ->> 'role';
  final_role public.user_role := 'customer';
  phone_value text := nullif(coalesce(new.phone, new.raw_user_meta_data ->> 'phone', ''), '');
begin
  if requested_role = 'vendor' then
    final_role := 'vendor';
  end if;
  insert into public.profiles (id, email, full_name, phone, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', ''), phone_value, final_role);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Guard triggers ----------
-- "Privileged" = admin session or trusted backend (service role / direct SQL: auth.uid() is null).
create or replace function public.is_privileged()
returns boolean language sql stable security definer set search_path = ''
as $$
  select (select auth.uid()) is null or public.is_admin();
$$;

-- role changes: only service role / SQL (never any signed-in user, not even admins)
create or replace function public.guard_profile_update()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is not null then
    if new.role is distinct from old.role then
      raise exception 'role can only be changed by the backend/service role' using errcode = '42501';
    end if;
    if not public.is_admin() and (new.status is distinct from old.status or new.email is distinct from old.email or new.id <> old.id) then
      raise exception 'status/email can only be changed by an administrator' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile_update();

create or replace function public.guard_vendor_profile()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if public.is_privileged() then
    if tg_op = 'UPDATE' and new.verification_status is distinct from old.verification_status then
      new.reviewed_by := coalesce(new.reviewed_by, (select auth.uid()));
      new.reviewed_at := coalesce(new.reviewed_at, now());
    end if;
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.verification_status <> 'pending' or new.reviewed_by is not null or new.reviewed_at is not null
       or new.review_notes is not null or new.rejection_reason is not null then
      raise exception 'verification fields are controlled by administrators' using errcode = '42501';
    end if;
  else
    if new.user_id <> old.user_id
       or new.verification_status is distinct from old.verification_status
       or new.reviewed_by is distinct from old.reviewed_by
       or new.reviewed_at is distinct from old.reviewed_at
       or new.review_notes is distinct from old.review_notes
       or new.rejection_reason is distinct from old.rejection_reason then
      raise exception 'verification fields are controlled by administrators' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger vendor_profiles_guard before insert or update on public.vendor_profiles
  for each row execute function public.guard_vendor_profile();

-- Public-safe vendor info ("seller information"). Excludes review notes and internal fields.
-- Intentionally SECURITY DEFINER (default view behaviour) so it can expose approved vendors to anon users.
create view public.vendor_public_profiles as
select v.id, v.business_name, v.business_types, v.description, v.address_line1, v.city, v.state,
       v.postal_code, v.contact_phone, v.contact_email, v.operating_hours, v.shop_image_paths,
       v.service_area_postal_codes, v.service_radius_km, v.pickup_available
from public.vendor_profiles v
join public.profiles p on p.id = v.user_id
where v.verification_status = 'approved' and p.status = 'active';
grant select on public.vendor_public_profiles to anon, authenticated;
