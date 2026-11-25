-- 19: Admin console operations (Step 10).
--  * announcements: one row per admin broadcast. Each recipient still gets an ordinary row in public.notifications
--    (linked through notifications.announcement_id), so there is NO second notification system. Delivery here means "an in-app
--    notification row exists"; push delivery (FCM) is a later step.
--  * admin_send_announcement: resolves the audience and inserts the announcement + every notification in ONE transaction
--    (all recipients or none). Only active accounts receive anything.
--  * admin_announcement_stats / admin_report: read-only aggregates for the admin console.
-- Everything below is callable by the service role only; the backend verifies the caller is an active admin first.
-- Time buckets use the platform's local day (Asia/Kolkata), like the dashboard (migration 18).

-- FIX (found while building Step 10): the vendor-decision notifications written by the Step 9 admin console use related_type 'vendor_application',
-- which the original CHECK did not allow, so the insert would have been rejected by the real database (the in-memory test double does not enforce CHECKs).
-- The same list now also allows 'vendor_service' for admin actions on a vendor's service.
alter table public.notifications drop constraint notifications_related_type_check;
alter table public.notifications add constraint notifications_related_type_check check (
  related_type is null or related_type in ('order', 'vendor_order', 'payment', 'service_booking', 'pickup_dropoff', 'product', 'support_ticket', 'vendor_application', 'vendor_service'));

create table public.announcements (
  id              uuid primary key default gen_random_uuid(),
  title           text not null check (char_length(title) between 3 and 150),
  message         text not null check (char_length(message) between 3 and 2000),
  type            public.notification_type not null check (type in ('promotion', 'announcement', 'system')),
  audience        text not null check (audience in ('customers', 'vendors', 'specific')),
  recipient_count integer not null default 0 check (recipient_count >= 0),
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now()
);
create index announcements_created_idx on public.announcements (created_at desc);
create index announcements_created_by_idx on public.announcements (created_by) where created_by is not null;

alter table public.announcements enable row level security;
create policy announcements_admin_select on public.announcements for select to authenticated using (public.is_admin());
-- no insert/update/delete policy: announcements are written only by admin_send_announcement (service role)

alter table public.notifications add column announcement_id uuid references public.announcements (id) on delete set null;
create index notifications_announcement_idx on public.notifications (announcement_id) where announcement_id is not null;

create or replace function public.admin_send_announcement(
  p_title text, p_message text, p_type public.notification_type, p_audience text, p_user_ids uuid[], p_admin uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_n  integer;
begin
  if p_audience not in ('customers', 'vendors', 'specific') then
    raise exception 'CM:invalid_audience' using errcode = 'P0001';
  end if;
  insert into public.announcements (title, message, type, audience, created_by)
    values (p_title, p_message, p_type, p_audience, p_admin) returning id into v_id;
  insert into public.notifications (user_id, type, title, message, created_by, announcement_id)
    select p.id, p_type, p_title, p_message, p_admin, v_id
      from public.profiles p
     where p.status = 'active'
       and ((p_audience = 'customers' and p.role = 'customer')
         or (p_audience = 'vendors' and p.role = 'vendor')
         or (p_audience = 'specific' and p.id = any (coalesce(p_user_ids, '{}'::uuid[])) and p.role in ('customer', 'vendor')));
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'CM:no_recipients' using errcode = 'P0001';       -- rolls the announcement back too
  end if;
  update public.announcements set recipient_count = v_n where id = v_id;
  return jsonb_build_object('id', v_id, 'recipient_count', v_n);
end;
$$;

-- {announcement_id: {delivered, read}} for a page of announcements
create or replace function public.admin_announcement_stats(p_ids uuid[])
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_object_agg(s.announcement_id, jsonb_build_object('delivered', s.n, 'read', s.r)), '{}'::jsonb)
    from (select announcement_id, count(*) n, count(*) filter (where is_read) r
            from public.notifications where announcement_id = any (p_ids) group by announcement_id) s;
$$;

-- Reports. p_kind: orders | sales | vendors | customers | services | payments.   Period = inclusive local dates [p_from, p_to].
-- Definitions (also shown in the UI):
--   orders    : orders CREATED in the period.
--   sales     : vendor orders DELIVERED in the period; sales = item value (subtotal), commission = the snapshot taken at delivery.
--   payments  : payments CREATED in the period, except `collected` (paid_at) and `refunded` (processed_at), which follow the money.
--   services  : service bookings CREATED in the period.
create or replace function public.admin_report(p_kind text, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_r jsonb;
begin
  if p_kind = 'orders' then
    with o as (select * from public.orders where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
         days as (select d::date as day from generate_series(p_from, p_to, interval '1 day') d)
    select jsonb_build_object(
      'total', (select count(*) from o),
      'value', coalesce((select sum(total_amount) from o where status <> 'cancelled'), 0),
      'by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from o group by status) s), '{}'::jsonb),
      'by_payment_method', coalesce((select jsonb_object_agg(payment_method, n) from (select payment_method, count(*) n from o group by payment_method) s), '{}'::jsonb),
      'by_payment_status', coalesce((select jsonb_object_agg(payment_status, n) from (select payment_status, count(*) n from o group by payment_status) s), '{}'::jsonb),
      'series', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(x.n, 0), 'value', coalesce(x.v, 0)) order by d.day), '[]'::jsonb)
                   from days d left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n, sum(total_amount) filter (where status <> 'cancelled') v
                                            from o group by 1) x on x.day = d.day)
    ) into v_r;

  elsif p_kind = 'sales' then
    with vo as (select * from public.vendor_orders where status = 'delivered' and (delivered_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
         days as (select d::date as day from generate_series(p_from, p_to, interval '1 day') d)
    select jsonb_build_object(
      'delivered_orders', (select count(*) from vo),
      'gross_sales', coalesce((select sum(subtotal) from vo), 0),
      'delivery_charges', coalesce((select sum(delivery_charge) from vo), 0),
      'discounts', coalesce((select sum(discount_amount) from vo), 0),
      'commission', coalesce((select sum(commission_amount) from vo), 0),
      'series', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(x.n, 0), 'value', coalesce(x.v, 0)) order by d.day), '[]'::jsonb)
                   from days d left join (select (delivered_at at time zone 'Asia/Kolkata')::date as day, count(*) n, sum(subtotal) v from vo group by 1) x on x.day = d.day),
      'by_vendor', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sales desc, x.vendor_name), '[]'::jsonb)
                      from (select vo.vendor_id, v.business_name as vendor_name, count(*) as orders, sum(vo.subtotal) as sales, coalesce(sum(vo.commission_amount), 0) as commission
                              from vo join public.vendor_profiles v on v.id = vo.vendor_id group by vo.vendor_id, v.business_name
                             order by sales desc, vendor_name limit 20) x),
      'by_product', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sales desc, x.product_name), '[]'::jsonb)
                       from (select oi.product_id, oi.product_name, sum(oi.quantity)::int as units, sum(oi.line_total) as sales
                               from public.order_items oi join vo on vo.id = oi.vendor_order_id group by oi.product_id, oi.product_name
                              order by sales desc, product_name limit 20) x)
    ) into v_r;

  elsif p_kind = 'vendors' then
    with days as (select d::date as day from generate_series(p_from, p_to, interval '1 day') d)
    select jsonb_build_object(
      'total', (select count(*) from public.vendor_profiles),
      'new_in_period', (select count(*) from public.vendor_profiles where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
      'by_verification', coalesce((select jsonb_object_agg(verification_status, n) from (select verification_status, count(*) n from public.vendor_profiles group by 1) s), '{}'::jsonb),
      'by_account_status', coalesce((select jsonb_object_agg(status, n) from (select p.status, count(*) n from public.vendor_profiles v join public.profiles p on p.id = v.user_id group by p.status) s), '{}'::jsonb),
      'series', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(x.n, 0)) order by d.day), '[]'::jsonb)
                   from days d left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n from public.vendor_profiles group by 1) x on x.day = d.day),
      'performance', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sales desc, x.business_name), '[]'::jsonb)
                        from (select v.id as vendor_id, v.business_name, v.verification_status,
                                     (select count(*) from public.products p where p.vendor_id = v.id) as products,
                                     (select count(*) from public.vendor_orders o where o.vendor_id = v.id and o.status = 'delivered'
                                         and (o.delivered_at at time zone 'Asia/Kolkata')::date between p_from and p_to) as orders_delivered,
                                     coalesce((select sum(o.subtotal) from public.vendor_orders o where o.vendor_id = v.id and o.status = 'delivered'
                                         and (o.delivered_at at time zone 'Asia/Kolkata')::date between p_from and p_to), 0) as sales,
                                     (select count(*) from public.service_bookings b where b.vendor_id = v.id and b.status = 'completed'
                                         and (b.completed_at at time zone 'Asia/Kolkata')::date between p_from and p_to) as bookings_completed
                                from public.vendor_profiles v order by sales desc, v.business_name limit 20) x)
    ) into v_r;

  elsif p_kind = 'customers' then
    with days as (select d::date as day from generate_series(p_from, p_to, interval '1 day') d),
         o as (select * from public.orders where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
         b as (select * from public.service_bookings where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to)
    select jsonb_build_object(
      'total', (select count(*) from public.profiles where role = 'customer'),
      'new_in_period', (select count(*) from public.profiles where role = 'customer' and (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
      'by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.profiles where role = 'customer' group by status) s), '{}'::jsonb),
      'active_in_period', (select count(*) from (select customer_id from o union select customer_id from b) u),
      'orders_in_period', (select count(*) from o),
      'bookings_in_period', (select count(*) from b),
      'series', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(x.n, 0)) order by d.day), '[]'::jsonb)
                   from days d left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n from public.profiles where role = 'customer' group by 1) x on x.day = d.day),
      'top_customers', (select coalesce(jsonb_agg(to_jsonb(x) order by x.orders desc, x.order_value desc, x.full_name), '[]'::jsonb)
                          from (select p.id as customer_id, p.full_name, count(o.id) as orders,
                                       coalesce(sum(o.total_amount) filter (where o.status <> 'cancelled'), 0) as order_value,
                                       (select count(*) from b where b.customer_id = p.id) as bookings
                                  from public.profiles p join o on o.customer_id = p.id group by p.id, p.full_name
                                 order by orders desc, order_value desc, p.full_name limit 10) x)
    ) into v_r;

  elsif p_kind = 'services' then
    with b as (select * from public.service_bookings where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
         days as (select d::date as day from generate_series(p_from, p_to, interval '1 day') d),
         pr as (select r.* from public.pickup_dropoff_requests r join b on b.id = r.booking_id)
    select jsonb_build_object(
      'total', (select count(*) from b),
      'by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from b group by status) s), '{}'::jsonb),
      'completed_value', coalesce((select sum(coalesce(final_price, estimated_price)) from b where status = 'completed'), 0),
      'series', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(x.n, 0)) order by d.day), '[]'::jsonb)
                   from days d left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n from b group by 1) x on x.day = d.day),
      'by_vendor', (select coalesce(jsonb_agg(to_jsonb(x) order by x.total desc, x.vendor_name), '[]'::jsonb)
                      from (select b.vendor_id, v.business_name as vendor_name, count(*) as total, count(*) filter (where b.status = 'completed') as completed,
                                   count(*) filter (where b.status in ('cancelled', 'rejected')) as cancelled_or_rejected
                              from b join public.vendor_profiles v on v.id = b.vendor_id group by b.vendor_id, v.business_name order by total desc, vendor_name limit 20) x),
      'by_category', (select coalesce(jsonb_agg(to_jsonb(x) order by x.total desc, x.category_name), '[]'::jsonb)
                        from (select coalesce(c.name, 'Uncategorised') as category_name, count(*) as total
                                from b left join public.service_categories c on c.id = b.service_category_id group by c.name order by total desc, category_name limit 20) x),
      'pickup', jsonb_build_object(
        'bookings_needing_pickup', (select count(*) from b where needs_pickup_dropoff),
        'requests', (select count(*) from pr),
        'pickup_by_status', coalesce((select jsonb_object_agg(pickup_status, n) from (select pickup_status, count(*) n from pr group by 1) s), '{}'::jsonb),
        'delivery_by_status', coalesce((select jsonb_object_agg(delivery_status, n) from (select delivery_status, count(*) n from pr group by 1) s), '{}'::jsonb))
    ) into v_r;

  elsif p_kind = 'payments' then
    with p as (select * from public.payments where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
         paid as (select * from public.payments where status in ('successful', 'partially_refunded', 'refunded') and (paid_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
         rf as (select * from public.refunds where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
         days as (select d::date as day from generate_series(p_from, p_to, interval '1 day') d)
    select jsonb_build_object(
      'total', (select count(*) from p),
      'by_status', coalesce((select jsonb_object_agg(status, jsonb_build_object('count', n, 'amount', a)) from (select status, count(*) n, sum(amount) a from p group by status) s), '{}'::jsonb),
      'by_method', coalesce((select jsonb_object_agg(method, jsonb_build_object('count', n, 'amount', a)) from (select method, count(*) n, sum(amount) a from p group by method) s), '{}'::jsonb),
      'collected', coalesce((select sum(amount) from paid), 0),
      'collected_by_method', coalesce((select jsonb_object_agg(method, jsonb_build_object('count', n, 'amount', a)) from (select method, count(*) n, sum(amount) a from paid group by method) s), '{}'::jsonb),
      'refunded', coalesce((select sum(amount) from public.refunds where status = 'processed' and (processed_at at time zone 'Asia/Kolkata')::date between p_from and p_to), 0),
      'refunds_by_status', coalesce((select jsonb_object_agg(status, jsonb_build_object('count', n, 'amount', a)) from (select status, count(*) n, sum(amount) a from rf group by status) s), '{}'::jsonb),
      'commission', coalesce((select sum(commission_amount) from public.vendor_orders where status = 'delivered' and (delivered_at at time zone 'Asia/Kolkata')::date between p_from and p_to), 0),
      'series', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(x.n, 0), 'value', coalesce(x.v, 0)) order by d.day), '[]'::jsonb)
                   from days d left join (select (paid_at at time zone 'Asia/Kolkata')::date as day, count(*) n, sum(amount) v from paid group by 1) x on x.day = d.day)
    ) into v_r;

  else
    raise exception 'CM:invalid_report' using errcode = 'P0001';
  end if;
  return v_r;
end;
$$;

revoke execute on function public.admin_send_announcement(text, text, public.notification_type, text, uuid[], uuid), public.admin_announcement_stats(uuid[]),
  public.admin_report(text, date, date) from public, anon, authenticated;
grant execute on function public.admin_send_announcement(text, text, public.notification_type, text, uuid[], uuid), public.admin_announcement_stats(uuid[]),
  public.admin_report(text, date, date) to service_role;
