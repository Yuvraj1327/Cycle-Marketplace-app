-- 04: banners, coupons, commission rules, platform settings
-- service_categories is needed by commission_rules, so it is created here (its vendor_services live in migration 06).

create table public.service_categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null unique,
  description text,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger service_categories_set_updated_at before update on public.service_categories
  for each row execute function public.set_updated_at();

create table public.banners (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  subtitle     text,
  image_path   text not null,
  action_type  text not null default 'none' check (action_type in ('none', 'product', 'category', 'service', 'url')),
  action_value text,
  sort_order   integer not null default 0,
  is_active    boolean not null default true,
  starts_at    timestamptz,
  ends_at      timestamptz,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint banners_valid_window check (ends_at is null or starts_at is null or ends_at > starts_at)
);
create index banners_active_idx on public.banners (sort_order) where is_active;
create trigger banners_set_updated_at before update on public.banners
  for each row execute function public.set_updated_at();

create table public.coupons (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null,
  description         text,
  discount_type       public.discount_type not null,
  discount_value      numeric(12,2) not null check (discount_value > 0),
  max_discount_amount numeric(12,2) check (max_discount_amount is null or max_discount_amount >= 0),
  min_order_amount    numeric(12,2) not null default 0 check (min_order_amount >= 0),
  applies_to          public.coupon_scope not null default 'all',
  valid_from          timestamptz not null default now(),
  valid_until         timestamptz,
  usage_limit         integer check (usage_limit is null or usage_limit > 0),
  per_user_limit      integer check (per_user_limit is null or per_user_limit > 0),
  used_count          integer not null default 0 check (used_count >= 0),
  is_active           boolean not null default true,
  created_by          uuid references public.profiles (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint coupons_percentage_max check (discount_type <> 'percentage' or discount_value <= 100),
  constraint coupons_valid_window check (valid_until is null or valid_until > valid_from)
);
create unique index coupons_code_key on public.coupons (upper(code));
create trigger coupons_set_updated_at before update on public.coupons
  for each row execute function public.set_updated_at();

-- Extensible commission configuration: most specific active rule wins (vendor > category > global), then priority.
create table public.commission_rules (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  applies_to          public.commission_scope not null,
  vendor_id           uuid references public.vendor_profiles (id) on delete cascade,
  category_id         uuid references public.categories (id) on delete cascade,
  service_category_id uuid references public.service_categories (id) on delete cascade,
  commission_type     public.discount_type not null default 'percentage',
  commission_value    numeric(12,2) not null check (commission_value >= 0),
  priority            integer not null default 0,
  is_active           boolean not null default true,
  effective_from      timestamptz not null default now(),
  effective_until     timestamptz,
  created_by          uuid references public.profiles (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint commission_percentage_max check (commission_type <> 'percentage' or commission_value <= 100),
  constraint commission_scope_targets check (
    (applies_to = 'product' and service_category_id is null) or
    (applies_to = 'service' and category_id is null)
  ),
  constraint commission_valid_window check (effective_until is null or effective_until > effective_from)
);
create index commission_rules_lookup_idx on public.commission_rules (applies_to, is_active, vendor_id);
create trigger commission_rules_set_updated_at before update on public.commission_rules
  for each row execute function public.set_updated_at();

-- Key/value settings (delivery charge, pickup charge, COD enabled, support contact...). Values are decided by the client/admin; none are seeded.
create table public.platform_settings (
  key         text primary key check (key ~ '^[a-z0-9_.]+$'),
  value       jsonb not null,
  description text,
  is_public   boolean not null default false,
  updated_by  uuid references public.profiles (id) on delete set null,
  updated_at  timestamptz not null default now()
);
create trigger platform_settings_set_updated_at before update on public.platform_settings
  for each row execute function public.set_updated_at();
