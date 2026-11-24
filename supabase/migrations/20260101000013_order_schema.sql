-- 13: Step 5 schema additions (additive) + one deliberate security tightening.
--
-- Reasons:
--  * orders.payment_status / idempotency_key / request_hash / payment_due_at: payment state on the order record,
--    duplicate-checkout protection, and the unpaid-reservation deadline.
--  * vendor_orders.vendor_name / released_at: historical vendor name; an order is only visible/actionable to the vendor
--    once it is confirmed (COD at checkout, online after verified payment).
--  * order_items.stock_restored_at / commission_*: stock can be restored exactly once; exact commission snapshot per line.
--  * payments.refunded_amount / needs_review / recorded_by: refund tracking, mismatch flagging, who recorded a COD collection.
--  * payment_events: webhook idempotency + audit of every provider event.
--  * vendor_settlements: per-vendor-order settlement RECORDS (no payouts are executed).
--  * audit_log: admin/financial actions.
--  * DROPS policy vendor_orders_vendor_update: it let vendors change status straight through Supabase, which would skip
--    stock restoration and refund handling. All fulfilment changes now go through the backend (service role).

alter table public.orders
  add column payment_status    public.payment_status not null default 'pending',
  add column idempotency_key   text,
  add column request_hash      text,
  add column payment_due_at    timestamptz,
  add column cancelled_at      timestamptz,
  add column cancelled_by      uuid references public.profiles (id) on delete set null,
  add column cancelled_by_role text check (cancelled_by_role in ('customer', 'vendor', 'admin', 'system'));
create unique index orders_idempotency_key on public.orders (customer_id, idempotency_key) where idempotency_key is not null;
create index orders_unpaid_due_idx on public.orders (payment_due_at) where status = 'pending' and payment_method = 'online';
create index orders_payment_status_idx on public.orders (payment_status);

alter table public.vendor_orders
  add column vendor_name  text,
  add column released_at  timestamptz,
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references public.profiles (id) on delete set null;
create index vendor_orders_released_idx on public.vendor_orders (vendor_id, released_at desc) where released_at is not null;

alter table public.order_items
  add column stock_restored_at timestamptz,
  add column commission_rule_id uuid references public.commission_rules (id) on delete set null,
  add column commission_amount numeric(12,2) not null default 0 check (commission_amount >= 0);
create index order_items_commission_rule_idx on public.order_items (commission_rule_id) where commission_rule_id is not null;

alter table public.payments
  add column refunded_amount numeric(12,2) not null default 0,
  add column needs_review    boolean not null default false,
  add column review_reason   text,
  add column recorded_by     uuid references public.profiles (id) on delete set null,
  add constraint payments_refunded_within_amount check (refunded_amount >= 0 and refunded_amount <= amount);
create index payments_provider_order_idx on public.payments (provider, provider_order_id) where provider_order_id is not null;
create index payments_recorded_by_idx on public.payments (recorded_by) where recorded_by is not null;
-- at most one OPEN attempt per order (retries create a new row only after the previous one failed/was cancelled)
create unique index payments_one_open_attempt on public.payments (order_id) where order_id is not null and status in ('pending', 'processing');

alter table public.refunds
  add column order_id uuid references public.orders (id) on delete restrict,
  add column idempotency_key text,
  add column provider text,
  add column failure_reason text;
create unique index refunds_idempotency_key on public.refunds (idempotency_key) where idempotency_key is not null;
create index refunds_order_idx on public.refunds (order_id) where order_id is not null;

create table public.payment_events (
  id                  uuid primary key default gen_random_uuid(),
  provider            text not null,
  event_id            text not null,
  event_type          text not null,
  payment_id          uuid references public.payments (id) on delete set null,
  provider_order_id   text,
  provider_payment_id text,
  amount              numeric(12,2),
  currency            char(3),
  outcome             text not null default 'received',
  created_at          timestamptz not null default now(),
  unique (provider, event_id)
);
create index payment_events_payment_idx on public.payment_events (payment_id) where payment_id is not null;

create table public.vendor_settlements (
  id               uuid primary key default gen_random_uuid(),
  vendor_id        uuid not null references public.vendor_profiles (id) on delete restrict,
  vendor_order_id  uuid not null unique references public.vendor_orders (id) on delete restrict,
  gross_amount     numeric(12,2) not null check (gross_amount >= 0),
  commission_amount numeric(12,2) not null default 0 check (commission_amount >= 0),
  deductions_amount numeric(12,2) not null default 0 check (deductions_amount >= 0),
  net_amount       numeric(12,2) not null,
  status           public.settlement_status not null default 'pending',
  payout_reference text,
  settled_at       timestamptz,
  settled_by       uuid references public.profiles (id) on delete set null,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint settlement_net_consistent check (net_amount = gross_amount - commission_amount - deductions_amount)
);
create index vendor_settlements_vendor_idx on public.vendor_settlements (vendor_id, status);
create index vendor_settlements_settled_by_idx on public.vendor_settlements (settled_by) where settled_by is not null;
create trigger vendor_settlements_set_updated_at before update on public.vendor_settlements
  for each row execute function public.set_updated_at();

create table public.audit_log (
  id          uuid primary key default gen_random_uuid(),
  actor_id    uuid references public.profiles (id) on delete set null,
  actor_role  text,
  action      text not null,
  entity_type text not null,
  entity_id   uuid,
  details     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index audit_log_entity_idx on public.audit_log (entity_type, entity_id, created_at desc);
create index audit_log_actor_idx on public.audit_log (actor_id) where actor_id is not null;

-- ---------- RLS ----------
alter table public.payment_events    enable row level security;
alter table public.vendor_settlements enable row level security;
alter table public.audit_log         enable row level security;

create policy payment_events_admin_select on public.payment_events for select to authenticated using (public.is_admin());
create policy audit_log_admin_select on public.audit_log for select to authenticated using (public.is_admin());
create policy settlements_select on public.vendor_settlements for select to authenticated
  using (vendor_id = public.current_vendor_id() or public.is_admin());
create policy settlements_admin_write on public.vendor_settlements for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- vendors can no longer change fulfilment directly through the Supabase API (see header)
drop policy vendor_orders_vendor_update on public.vendor_orders;

-- history rows written by backend functions keep the real actor + note (auth.uid() is null for the service role)
create or replace function public.log_vendor_order_status()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_status_history (order_id, vendor_order_id, from_status, to_status, changed_by, note)
    values (new.order_id, new.id, case when tg_op = 'UPDATE' then old.status::text end, new.status::text,
            coalesce((select auth.uid()), nullif(current_setting('app.actor_id', true), '')::uuid),
            nullif(current_setting('app.status_note', true), ''));
  end if;
  return null;
end;
$$;

create or replace function public.log_order_status()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_status_history (order_id, from_status, to_status, changed_by, note)
    values (new.id, case when tg_op = 'UPDATE' then old.status::text end, new.status::text,
            coalesce((select auth.uid()), nullif(current_setting('app.actor_id', true), '')::uuid),
            nullif(current_setting('app.status_note', true), ''));
  end if;
  return null;
end;
$$;
