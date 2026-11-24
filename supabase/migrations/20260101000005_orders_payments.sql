-- 05: orders (customer checkout) -> vendor_orders (per-vendor fulfilment) -> order_items; payments; refunds

create sequence public.order_number_seq;
create sequence public.vendor_order_number_seq;

create table public.orders (
  id                  uuid primary key default gen_random_uuid(),
  order_number        text not null unique default ('ORD-' || lpad(nextval('public.order_number_seq')::text, 8, '0')),
  customer_id         uuid not null references public.profiles (id) on delete restrict,
  status              public.order_status not null default 'pending',
  payment_method      public.payment_method not null,
  delivery_address_id uuid references public.user_addresses (id) on delete set null,
  delivery_address    jsonb not null,                       -- snapshot at checkout
  subtotal            numeric(12,2) not null check (subtotal >= 0),
  delivery_charge     numeric(12,2) not null default 0 check (delivery_charge >= 0),
  discount_amount     numeric(12,2) not null default 0 check (discount_amount >= 0),
  total_amount        numeric(12,2) not null check (total_amount >= 0),
  coupon_id           uuid references public.coupons (id) on delete set null,
  coupon_code         text,                                 -- snapshot
  customer_note       text,
  cancelled_reason    text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint orders_total_consistent check (total_amount = subtotal + delivery_charge - discount_amount)
);
create index orders_customer_idx on public.orders (customer_id, created_at desc);
create index orders_status_idx on public.orders (status);
create index orders_coupon_idx on public.orders (coupon_id) where coupon_id is not null;
create trigger orders_set_updated_at before update on public.orders
  for each row execute function public.set_updated_at();

create table public.vendor_orders (
  id                  uuid primary key default gen_random_uuid(),
  vendor_order_number text not null unique default ('VO-' || lpad(nextval('public.vendor_order_number_seq')::text, 8, '0')),
  order_id            uuid not null references public.orders (id) on delete cascade,
  vendor_id           uuid not null references public.vendor_profiles (id) on delete restrict,
  status              public.vendor_order_status not null default 'pending',
  subtotal            numeric(12,2) not null check (subtotal >= 0),
  delivery_charge     numeric(12,2) not null default 0 check (delivery_charge >= 0),
  discount_amount     numeric(12,2) not null default 0 check (discount_amount >= 0),
  total_amount        numeric(12,2) not null check (total_amount >= 0),
  commission_rule_id  uuid references public.commission_rules (id) on delete set null,
  commission_amount   numeric(12,2) check (commission_amount is null or commission_amount >= 0),  -- snapshot at completion
  vendor_note         text,
  rejection_reason    text,
  cancellation_reason text,
  accepted_at         timestamptz,
  delivered_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (order_id, vendor_id),
  constraint vendor_orders_total_consistent check (total_amount = subtotal + delivery_charge - discount_amount)
);
create index vendor_orders_vendor_idx on public.vendor_orders (vendor_id, status, created_at desc);
create trigger vendor_orders_set_updated_at before update on public.vendor_orders
  for each row execute function public.set_updated_at();

create table public.order_items (
  id                 uuid primary key default gen_random_uuid(),
  order_id           uuid not null references public.orders (id) on delete cascade,
  vendor_order_id    uuid not null references public.vendor_orders (id) on delete cascade,
  product_id         uuid references public.products (id) on delete set null,
  product_name       text not null,        -- snapshots
  product_brand      text,
  product_model      text,
  product_condition  public.product_condition,
  product_image_path text,
  unit_price         numeric(12,2) not null check (unit_price >= 0),
  quantity           integer not null check (quantity > 0),
  line_total         numeric(12,2) not null,
  created_at         timestamptz not null default now(),
  constraint order_items_line_total_consistent check (line_total = unit_price * quantity)
);
create index order_items_order_idx on public.order_items (order_id);
create index order_items_vendor_order_idx on public.order_items (vendor_order_id);
create index order_items_product_idx on public.order_items (product_id) where product_id is not null;

-- Status history for vendor fulfilment and customer-level order changes (vendor_order_id null => order-level).
create table public.order_status_history (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders (id) on delete cascade,
  vendor_order_id uuid references public.vendor_orders (id) on delete cascade,
  from_status     text,
  to_status       text not null,
  changed_by      uuid references public.profiles (id) on delete set null,
  note            text,
  created_at      timestamptz not null default now()
);
create index order_status_history_order_idx on public.order_status_history (order_id, created_at);
create index order_status_history_vo_idx on public.order_status_history (vendor_order_id, created_at);

create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null references public.profiles (id) on delete restrict,
  order_id            uuid references public.orders (id) on delete restrict,
  service_booking_id  uuid,   -- FK added in migration 06 (service_bookings does not exist yet)
  method              public.payment_method not null,
  provider            text,   -- gateway not chosen yet
  provider_order_id   text,
  provider_payment_id text,
  amount              numeric(12,2) not null check (amount >= 0),
  currency            char(3) not null default 'INR',
  status              public.payment_status not null default 'pending',
  failure_reason      text,
  paid_at             timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint payments_single_target check (num_nonnulls(order_id, service_booking_id) = 1)
);
create index payments_customer_idx on public.payments (customer_id, created_at desc);
create index payments_order_idx on public.payments (order_id) where order_id is not null;
create index payments_booking_idx on public.payments (service_booking_id) where service_booking_id is not null;
create index payments_status_idx on public.payments (status);
create unique index payments_provider_ref_key on public.payments (provider, provider_payment_id) where provider_payment_id is not null;
create trigger payments_set_updated_at before update on public.payments
  for each row execute function public.set_updated_at();

create table public.refunds (
  id                 uuid primary key default gen_random_uuid(),
  payment_id         uuid not null references public.payments (id) on delete restrict,
  vendor_order_id    uuid references public.vendor_orders (id) on delete set null,
  amount             numeric(12,2) not null check (amount > 0),
  reason             text,
  status             public.refund_status not null default 'requested',
  provider_refund_id text,
  requested_by       uuid references public.profiles (id) on delete set null,
  processed_by       uuid references public.profiles (id) on delete set null,
  processed_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index refunds_payment_idx on public.refunds (payment_id);
create index refunds_status_idx on public.refunds (status);
create trigger refunds_set_updated_at before update on public.refunds
  for each row execute function public.set_updated_at();

-- ---------- Integrity helpers ----------
create or replace function public.customer_owns_order(oid uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.orders where id = oid and customer_id = (select auth.uid()));
$$;

-- vendors may only touch fulfilment fields; money/ownership columns are immutable for them
create or replace function public.guard_vendor_order()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_privileged() then
    if new.order_id <> old.order_id or new.vendor_id <> old.vendor_id
       or new.subtotal <> old.subtotal or new.delivery_charge <> old.delivery_charge
       or new.discount_amount <> old.discount_amount or new.total_amount <> old.total_amount
       or new.commission_rule_id is distinct from old.commission_rule_id
       or new.commission_amount is distinct from old.commission_amount then
      raise exception 'only fulfilment fields of a vendor order can be changed' using errcode = '42501';
    end if;
  end if;
  if new.status is distinct from old.status then
    if not public.is_admin() and not (
      (old.status = 'pending'            and new.status in ('accepted', 'rejected', 'cancelled')) or
      (old.status = 'accepted'           and new.status in ('preparing', 'cancelled')) or
      (old.status = 'preparing'          and new.status in ('ready_for_dispatch', 'cancelled')) or
      (old.status = 'ready_for_dispatch' and new.status in ('out_for_delivery', 'delivered', 'cancelled')) or
      (old.status = 'out_for_delivery'   and new.status in ('delivered', 'cancelled'))
    ) then
      raise exception 'invalid vendor order status transition % -> %', old.status, new.status;
    end if;
    if new.status = 'accepted'  then new.accepted_at  := coalesce(new.accepted_at, now()); end if;
    if new.status = 'delivered' then new.delivered_at := coalesce(new.delivered_at, now()); end if;
  end if;
  return new;
end;
$$;
create trigger vendor_orders_guard before update on public.vendor_orders
  for each row execute function public.guard_vendor_order();

create or replace function public.log_vendor_order_status()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_status_history (order_id, vendor_order_id, from_status, to_status, changed_by)
    values (new.order_id, new.id, case when tg_op = 'UPDATE' then old.status::text end, new.status::text, (select auth.uid()));
  end if;
  return null;
end;
$$;
create trigger vendor_orders_log_status after insert or update of status on public.vendor_orders
  for each row execute function public.log_vendor_order_status();

create or replace function public.log_order_status()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_status_history (order_id, from_status, to_status, changed_by)
    values (new.id, case when tg_op = 'UPDATE' then old.status::text end, new.status::text, (select auth.uid()));
  end if;
  return null;
end;
$$;
create trigger orders_log_status after insert or update of status on public.orders
  for each row execute function public.log_order_status();
