-- 03: categories, products, images, carts, wishlists

create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  parent_id   uuid references public.categories (id) on delete restrict,
  kind        public.category_kind not null,
  name        text not null,
  slug        text not null unique,
  description text,
  image_path  text,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint categories_not_self_parent check (parent_id is null or parent_id <> id)
);
create index categories_parent_idx on public.categories (parent_id);
create index categories_kind_idx on public.categories (kind) where is_active;
create trigger categories_set_updated_at before update on public.categories
  for each row execute function public.set_updated_at();

create table public.products (
  id              uuid primary key default gen_random_uuid(),
  vendor_id       uuid not null references public.vendor_profiles (id) on delete restrict,
  category_id     uuid not null references public.categories (id) on delete restrict,
  product_type    public.category_kind not null,
  name            text not null,
  description     text,
  brand           text,
  model           text,
  specifications  jsonb not null default '{}'::jsonb,
  condition       public.product_condition not null,
  price           numeric(12,2) not null check (price >= 0),
  stock_quantity  integer not null default 0 check (stock_quantity >= 0),
  is_available    boolean not null default true,   -- vendor-controlled availability toggle
  is_active       boolean not null default true,   -- vendor "deactivate listing" (soft remove)
  approval_status public.listing_status not null default 'pending',
  reviewed_by     uuid references public.profiles (id) on delete set null,
  reviewed_at     timestamptz,
  review_notes    text,
  is_featured     boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint products_condition_matches_type check (
    (product_type = 'new_cycle' and condition = 'new') or
    (product_type = 'used_cycle' and condition = 'used') or
    product_type in ('spare_part', 'accessory')
  )
);
create index products_vendor_idx on public.products (vendor_id);
create index products_category_idx on public.products (category_id);
create index products_public_idx on public.products (product_type, price) where is_active and approval_status = 'approved';
create index products_featured_idx on public.products (is_featured) where is_featured;
create index products_brand_idx on public.products (lower(brand));
create index products_name_search_idx on public.products using gin (to_tsvector('simple', name || ' ' || coalesce(brand, '') || ' ' || coalesce(model, '')));
create trigger products_set_updated_at before update on public.products
  for each row execute function public.set_updated_at();

-- product_type must match its category's kind
create or replace function public.validate_product()
returns trigger language plpgsql set search_path = ''
as $$
declare cat_kind public.category_kind;
begin
  select kind into cat_kind from public.categories where id = new.category_id;
  if cat_kind is distinct from new.product_type then
    raise exception 'product_type (%) does not match category kind (%)', new.product_type, cat_kind;
  end if;
  return new;
end;
$$;
create trigger products_validate before insert or update of category_id, product_type on public.products
  for each row execute function public.validate_product();

-- admin-only fields: approval + featured flag
create or replace function public.guard_product()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if public.is_privileged() then
    if tg_op = 'UPDATE' and new.approval_status is distinct from old.approval_status then
      new.reviewed_by := coalesce(new.reviewed_by, (select auth.uid()));
      new.reviewed_at := coalesce(new.reviewed_at, now());
    end if;
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.approval_status <> 'pending' or new.is_featured or new.reviewed_by is not null
       or new.reviewed_at is not null or new.review_notes is not null then
      raise exception 'approval/featured fields are controlled by administrators' using errcode = '42501';
    end if;
  else
    if new.vendor_id <> old.vendor_id
       or new.approval_status is distinct from old.approval_status
       or new.is_featured is distinct from old.is_featured
       or new.reviewed_by is distinct from old.reviewed_by
       or new.reviewed_at is distinct from old.reviewed_at
       or new.review_notes is distinct from old.review_notes then
      raise exception 'approval/featured fields are controlled by administrators' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger products_guard before insert or update on public.products
  for each row execute function public.guard_product();

create table public.product_images (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references public.products (id) on delete cascade,
  storage_path text not null,
  alt_text     text,
  sort_order   integer not null default 0,
  is_primary   boolean not null default false,
  created_at   timestamptz not null default now()
);
create index product_images_product_idx on public.product_images (product_id, sort_order);
create unique index product_images_one_primary_idx on public.product_images (product_id) where is_primary;

create table public.carts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null unique references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger carts_set_updated_at before update on public.carts
  for each row execute function public.set_updated_at();

-- Prices are NOT stored in the cart; they are read from products at checkout (snapshotted into order_items).
-- A cart may hold products of several vendors (schema allows it; business rule still pending client decision).
create table public.cart_items (
  id         uuid primary key default gen_random_uuid(),
  cart_id    uuid not null references public.carts (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  quantity   integer not null check (quantity > 0 and quantity <= 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cart_id, product_id)
);
create index cart_items_product_idx on public.cart_items (product_id);
create trigger cart_items_set_updated_at before update on public.cart_items
  for each row execute function public.set_updated_at();

create table public.wishlists (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null unique references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.wishlist_items (
  id          uuid primary key default gen_random_uuid(),
  wishlist_id uuid not null references public.wishlists (id) on delete cascade,
  product_id  uuid not null references public.products (id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (wishlist_id, product_id)
);
create index wishlist_items_product_idx on public.wishlist_items (product_id);
