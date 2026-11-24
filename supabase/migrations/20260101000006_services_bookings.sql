-- 06: vendor services, service bookings, images, status history, pickup/drop-off
-- (service_categories already exists from migration 04)

create sequence public.booking_number_seq;

create table public.vendor_services (
  id                         uuid primary key default gen_random_uuid(),
  vendor_id                  uuid not null references public.vendor_profiles (id) on delete cascade,
  service_category_id        uuid not null references public.service_categories (id) on delete restrict,
  name                       text not null,
  description                text,
  price                      numeric(12,2) not null check (price >= 0),
  estimated_duration_minutes integer check (estimated_duration_minutes is null or estimated_duration_minutes > 0),
  is_active                  boolean not null default true,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),
  unique (vendor_id, service_category_id, name)
);
create index vendor_services_vendor_idx on public.vendor_services (vendor_id);
create index vendor_services_category_idx on public.vendor_services (service_category_id) where is_active;
create trigger vendor_services_set_updated_at before update on public.vendor_services
  for each row execute function public.set_updated_at();

create table public.service_bookings (
  id                   uuid primary key default gen_random_uuid(),
  booking_number       text not null unique default ('BKG-' || lpad(nextval('public.booking_number_seq')::text, 8, '0')),
  customer_id          uuid not null references public.profiles (id) on delete restrict,
  vendor_id            uuid not null references public.vendor_profiles (id) on delete restrict,
  vendor_service_id    uuid references public.vendor_services (id) on delete set null,
  service_name         text not null,                 -- snapshot
  cycle_brand          text,
  cycle_model          text,
  cycle_details        text,
  issue_description    text not null,
  preferred_date       date not null,
  preferred_slot_start time not null,
  preferred_slot_end   time not null,
  needs_pickup_dropoff boolean not null default false,
  estimated_price      numeric(12,2) not null check (estimated_price >= 0),  -- snapshot of vendor service price
  final_price          numeric(12,2) check (final_price is null or final_price >= 0),
  price_change_reason  text,
  status               public.booking_status not null default 'pending',
  vendor_notes         text,
  rejection_reason     text,
  cancellation_reason  text,
  cancelled_by         uuid references public.profiles (id) on delete set null,
  accepted_at          timestamptz,
  completed_at         timestamptz,
  completion_notes     text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint booking_slot_valid check (preferred_slot_end > preferred_slot_start),
  constraint booking_completion_consistent check (status <> 'completed' or completed_at is not null)
);
create index service_bookings_customer_idx on public.service_bookings (customer_id, created_at desc);
create index service_bookings_vendor_idx on public.service_bookings (vendor_id, status, preferred_date);
create index service_bookings_status_idx on public.service_bookings (status);
create trigger service_bookings_set_updated_at before update on public.service_bookings
  for each row execute function public.set_updated_at();

alter table public.payments
  add constraint payments_service_booking_fk foreign key (service_booking_id)
  references public.service_bookings (id) on delete restrict;

create table public.service_booking_images (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null references public.service_bookings (id) on delete cascade,
  storage_path text not null,
  uploaded_by  uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index service_booking_images_booking_idx on public.service_booking_images (booking_id);

create table public.booking_status_history (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.service_bookings (id) on delete cascade,
  from_status public.booking_status,
  to_status   public.booking_status not null,
  changed_by  uuid references public.profiles (id) on delete set null,
  note        text,
  created_at  timestamptz not null default now()
);
create index booking_status_history_booking_idx on public.booking_status_history (booking_id, created_at);

-- Pickup/drop-off tracking is deliberately separate from service_bookings.status.
create table public.pickup_dropoff_requests (
  id                    uuid primary key default gen_random_uuid(),
  booking_id            uuid not null references public.service_bookings (id) on delete cascade,
  pickup_address_id     uuid references public.user_addresses (id) on delete set null,
  pickup_address        jsonb not null,               -- snapshot
  dropoff_address_id    uuid references public.user_addresses (id) on delete set null,
  dropoff_address       jsonb not null,               -- snapshot
  scheduled_pickup_at   timestamptz,
  scheduled_delivery_at timestamptz,
  pickup_charge         numeric(12,2) not null default 0 check (pickup_charge >= 0),
  dropoff_charge        numeric(12,2) not null default 0 check (dropoff_charge >= 0),
  pickup_status         public.logistics_status not null default 'pending',
  delivery_status       public.logistics_status not null default 'pending',
  picked_up_at          timestamptz,
  delivered_at          timestamptz,
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint pickup_schedule_order check (scheduled_delivery_at is null or scheduled_pickup_at is null or scheduled_delivery_at > scheduled_pickup_at)
);
create index pickup_dropoff_booking_idx on public.pickup_dropoff_requests (booking_id);
create index pickup_dropoff_status_idx on public.pickup_dropoff_requests (pickup_status, delivery_status);
create trigger pickup_dropoff_set_updated_at before update on public.pickup_dropoff_requests
  for each row execute function public.set_updated_at();

-- ---------- Guards & history ----------
create or replace function public.guard_service_booking()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_privileged() then
    if new.customer_id <> old.customer_id or new.vendor_id <> old.vendor_id
       or new.booking_number <> old.booking_number or new.estimated_price <> old.estimated_price
       or new.vendor_service_id is distinct from old.vendor_service_id
       or new.issue_description <> old.issue_description then
      raise exception 'only vendor-managed booking fields can be changed' using errcode = '42501';
    end if;
  end if;
  if new.status is distinct from old.status then
    if not public.is_admin() and not (
      (old.status = 'pending'            and new.status in ('accepted', 'rejected', 'cancelled')) or
      (old.status = 'accepted'           and new.status in ('picked_up', 'cancelled')) or
      (old.status = 'picked_up'          and new.status = 'in_service') or
      (old.status = 'in_service'         and new.status = 'ready_for_delivery') or
      (old.status = 'ready_for_delivery' and new.status = 'completed')
    ) then
      raise exception 'invalid booking status transition % -> %', old.status, new.status;
    end if;
    if new.status = 'accepted'  then new.accepted_at  := coalesce(new.accepted_at, now()); end if;
    if new.status = 'completed' then new.completed_at := coalesce(new.completed_at, now()); end if;
  end if;
  return new;
end;
$$;
create trigger service_bookings_guard before update on public.service_bookings
  for each row execute function public.guard_service_booking();

create or replace function public.log_booking_status()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.booking_status_history (booking_id, from_status, to_status, changed_by)
    values (new.id, case when tg_op = 'UPDATE' then old.status end, new.status, (select auth.uid()));
  end if;
  return null;
end;
$$;
create trigger service_bookings_log_status after insert or update of status on public.service_bookings
  for each row execute function public.log_booking_status();

create or replace function public.guard_pickup_dropoff()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_privileged() then
    if new.booking_id <> old.booking_id or new.pickup_charge <> old.pickup_charge
       or new.dropoff_charge <> old.dropoff_charge
       or new.pickup_address is distinct from old.pickup_address
       or new.dropoff_address is distinct from old.dropoff_address then
      raise exception 'only pickup/delivery progress fields can be changed' using errcode = '42501';
    end if;
  end if;
  if new.pickup_status = 'completed' and old.pickup_status <> 'completed' then
    new.picked_up_at := coalesce(new.picked_up_at, now());
  end if;
  if new.delivery_status = 'completed' and old.delivery_status <> 'completed' then
    new.delivered_at := coalesce(new.delivered_at, now());
  end if;
  return new;
end;
$$;
create trigger pickup_dropoff_guard before update on public.pickup_dropoff_requests
  for each row execute function public.guard_pickup_dropoff();
