-- 15: Step 6 schema (additive) + deliberate security tightening.
--  * vendor_services: service-specific availability (is_available, available_days) and slot capacity (slot_minutes, max_bookings_per_slot).
--  * service_bookings: CONFIRMED appointment (confirmed_*) kept separate from the customer's PREFERRED slot; snapshots; duplicate guard.
--  * service_charges: append-only record of additional repair charges (the original estimate is never overwritten).
--  * service_booking_notes: append-only service notes.
--  * pickup_dropoff_requests.customer_instructions.
--  * notifications.event_key: lets the backend insert each event once (duplicate prevention).
--  * service_categories.image_path.
--  * DROPS the vendor UPDATE policies on service_bookings and pickup_dropoff_requests: direct Supabase updates would bypass status
--    rules, history notes, notifications and charge history (a vendor could simply write final_price). Changes go through the backend.
--  * guard_service_booking / log_booking_status replaced: services without pickup may go accepted -> in_service; admins may cancel any
--    open booking; history keeps the real actor and note when the backend (service role) performs the change.

alter table public.service_categories add column image_path text;

alter table public.vendor_services
  add column is_available         boolean not null default true,
  add column available_days       text[],
  add column slot_minutes         integer not null default 60 check (slot_minutes between 15 and 240),
  add column max_bookings_per_slot integer not null default 1 check (max_bookings_per_slot between 1 and 20),
  add constraint vendor_services_days_valid check (available_days is null or available_days <@ array['mon','tue','wed','thu','fri','sat','sun']::text[]);

alter table public.service_bookings
  add column service_category_id uuid references public.service_categories (id) on delete restrict,
  add column vendor_name         text,
  add column estimated_duration_minutes integer,           -- snapshot of the service's quoted duration
  add column confirmed_date       date,
  add column confirmed_slot_start time,
  add column confirmed_slot_end   time,
  add constraint booking_confirmed_all_or_none check ((confirmed_date is null) = (confirmed_slot_start is null) and (confirmed_slot_start is null) = (confirmed_slot_end is null)),
  add constraint booking_confirmed_slot_valid check (confirmed_slot_end is null or confirmed_slot_end > confirmed_slot_start),
  add constraint booking_final_not_below_zero check (final_price is null or final_price >= 0);
create index service_bookings_category_idx on public.service_bookings (service_category_id);
create index service_bookings_confirmed_idx on public.service_bookings (vendor_service_id, confirmed_date, confirmed_slot_start) where status = 'accepted';
-- the same customer cannot have two open bookings for the same service in the same preferred slot
create unique index service_bookings_no_duplicates on public.service_bookings (customer_id, vendor_service_id, preferred_date, preferred_slot_start)
  where status in ('pending', 'accepted', 'picked_up', 'in_service', 'ready_for_delivery') and vendor_service_id is not null;

alter table public.pickup_dropoff_requests add column customer_instructions text;

alter table public.notifications add column event_key text;
create unique index notifications_event_key on public.notifications (user_id, event_key) where event_key is not null;

create table public.service_charges (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.service_bookings (id) on delete cascade,
  amount      numeric(12,2) not null check (amount <> 0),     -- negative = adjustment/correction
  reason      text not null,
  recorded_by uuid references public.profiles (id) on delete set null,
  recorded_role text,
  created_at  timestamptz not null default now()
);
create index service_charges_booking_idx on public.service_charges (booking_id, created_at);
create index service_charges_recorded_by_idx on public.service_charges (recorded_by) where recorded_by is not null;

create table public.service_booking_notes (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.service_bookings (id) on delete cascade,
  author_id   uuid references public.profiles (id) on delete set null,
  author_role text not null check (author_role in ('vendor', 'admin')),
  note        text not null check (length(btrim(note)) > 0),
  created_at  timestamptz not null default now()
);
create index service_booking_notes_booking_idx on public.service_booking_notes (booking_id, created_at);
create index service_booking_notes_author_idx on public.service_booking_notes (author_id) where author_id is not null;

alter table public.service_charges       enable row level security;
alter table public.service_booking_notes enable row level security;
create policy service_charges_select on public.service_charges for select to authenticated
  using (exists (select 1 from public.service_bookings b where b.id = booking_id));
create policy service_booking_notes_select on public.service_booking_notes for select to authenticated
  using (exists (select 1 from public.service_bookings b where b.id = booking_id));
create policy service_charges_admin_all on public.service_charges for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy service_booking_notes_admin_all on public.service_booking_notes for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy service_bookings_vendor_update on public.service_bookings;
drop policy pickup_dropoff_vendor_update on public.pickup_dropoff_requests;

create or replace function public.log_booking_status()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.booking_status_history (booking_id, from_status, to_status, changed_by, note)
    values (new.id, case when tg_op = 'UPDATE' then old.status end, new.status,
            coalesce((select auth.uid()), nullif(current_setting('app.actor_id', true), '')::uuid),
            nullif(current_setting('app.status_note', true), ''));
  end if;
  return null;
end;
$$;

create or replace function public.guard_service_booking()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare admin_actor boolean := public.is_admin() or current_setting('app.actor_role', true) = 'admin';
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
    if not (
      (old.status = 'pending'            and new.status in ('accepted', 'rejected', 'cancelled')) or
      (old.status = 'accepted'           and new.status in ('picked_up', 'cancelled')) or
      (old.status = 'accepted'           and new.status = 'in_service' and not new.needs_pickup_dropoff) or   -- customer brings the cycle in
      (old.status = 'picked_up'          and new.status = 'in_service') or
      (old.status = 'in_service'         and new.status = 'ready_for_delivery') or
      (old.status = 'ready_for_delivery' and new.status = 'completed') or
      (admin_actor and new.status = 'cancelled' and old.status in ('picked_up', 'in_service', 'ready_for_delivery'))
    ) then
      raise exception 'invalid booking status transition % -> %', old.status, new.status;
    end if;
    if new.status = 'accepted'  then new.accepted_at  := coalesce(new.accepted_at, now()); end if;
    if new.status = 'completed' then new.completed_at := coalesce(new.completed_at, now()); end if;
  end if;
  return new;
end;
$$;
