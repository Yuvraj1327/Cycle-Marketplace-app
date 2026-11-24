-- 07: notifications and customer support

create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  type         public.notification_type not null,
  title        text not null,
  message      text not null,
  related_type text check (related_type is null or related_type in ('order', 'vendor_order', 'payment', 'service_booking', 'pickup_dropoff', 'product', 'support_ticket')),
  related_id   uuid,
  is_read      boolean not null default false,
  read_at      timestamptz,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  constraint notifications_related_pair check ((related_type is null) = (related_id is null))
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where not is_read;

-- recipients may only mark their own notifications read/unread
create or replace function public.guard_notification()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_privileged() then
    if new.user_id <> old.user_id or new.type <> old.type or new.title <> old.title
       or new.message <> old.message or new.related_type is distinct from old.related_type
       or new.related_id is distinct from old.related_id or new.created_by is distinct from old.created_by then
      raise exception 'only the read state of a notification can be changed' using errcode = '42501';
    end if;
  end if;
  if new.is_read and not old.is_read then new.read_at := coalesce(new.read_at, now()); end if;
  if not new.is_read then new.read_at := null; end if;
  return new;
end;
$$;
create trigger notifications_guard before update on public.notifications
  for each row execute function public.guard_notification();

create sequence public.support_ticket_number_seq;

create table public.support_tickets (
  id                 uuid primary key default gen_random_uuid(),
  ticket_number      text not null unique default ('TKT-' || lpad(nextval('public.support_ticket_number_seq')::text, 8, '0')),
  requester_id       uuid not null references public.profiles (id) on delete restrict,
  type               public.support_ticket_type not null default 'support_request',
  subject            text not null,
  description        text not null,
  order_id           uuid references public.orders (id) on delete set null,
  service_booking_id uuid references public.service_bookings (id) on delete set null,
  status             public.support_ticket_status not null default 'open',
  assigned_to        uuid references public.profiles (id) on delete set null,
  admin_notes        text,
  resolution         text,
  resolved_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index support_tickets_requester_idx on public.support_tickets (requester_id, created_at desc);
create index support_tickets_status_idx on public.support_tickets (status, created_at);
create index support_tickets_order_idx on public.support_tickets (order_id) where order_id is not null;
create index support_tickets_booking_idx on public.support_tickets (service_booking_id) where service_booking_id is not null;
create trigger support_tickets_set_updated_at before update on public.support_tickets
  for each row execute function public.set_updated_at();
