-- 18: read-only aggregates for the Admin Web console (service_role only; the backend verifies the caller is an active admin first).
-- Nothing here writes data. Time buckets use the platform's local day (Asia/Kolkata).

-- Dashboard: counts by status, order/sales values, and per-day series for [p_from, p_to] (inclusive local dates).
create or replace function public.admin_dashboard_summary(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with days as (select d::date as day from generate_series(p_from, p_to, interval '1 day') d)
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'customers', jsonb_build_object(
      'total',      (select count(*) from public.profiles where role = 'customer'),
      'by_status',  coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.profiles where role = 'customer' group by status) s), '{}'::jsonb),
      'new_in_period', (select count(*) from public.profiles where role = 'customer' and (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to)),
    'vendors', jsonb_build_object(
      'total',      (select count(*) from public.vendor_profiles),
      'by_verification', coalesce((select jsonb_object_agg(verification_status, n) from (select verification_status, count(*) n from public.vendor_profiles group by verification_status) s), '{}'::jsonb),
      'by_account_status', coalesce((select jsonb_object_agg(status, n) from (
            select p.status, count(*) n from public.vendor_profiles v join public.profiles p on p.id = v.user_id group by p.status) s), '{}'::jsonb),
      'new_in_period', (select count(*) from public.vendor_profiles where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to)),
    'orders', jsonb_build_object(
      'total',      (select count(*) from public.orders),
      'by_status',  coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.orders group by status) s), '{}'::jsonb),
      'value_completed', coalesce((select sum(total_amount) from public.orders where status = 'completed'), 0),
      'value_confirmed', coalesce((select sum(total_amount) from public.orders where status = 'confirmed'), 0)),
    'bookings', jsonb_build_object(
      'total',      (select count(*) from public.service_bookings),
      'by_status',  coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.service_bookings group by status) s), '{}'::jsonb)),
    'series', jsonb_build_object(
      'orders',    (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(o.n, 0), 'value', coalesce(o.v, 0)) order by d.day), '[]'::jsonb) from days d
                     left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n, sum(total_amount) filter (where status <> 'cancelled') v from public.orders group by 1) o on o.day = d.day),
      'bookings',  (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(b.n, 0)) order by d.day), '[]'::jsonb) from days d
                     left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n from public.service_bookings group by 1) b on b.day = d.day),
      'customers', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(c.n, 0)) order by d.day), '[]'::jsonb) from days d
                     left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n from public.profiles where role = 'customer' group by 1) c on c.day = d.day),
      'vendors',   (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'count', coalesce(v.n, 0)) order by d.day), '[]'::jsonb) from days d
                     left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n from public.vendor_profiles group by 1) v on v.day = d.day))
  );
$$;

-- Per-row activity counts for a page of customers or vendors (avoids N+1 queries from the list screens).
-- kind = 'customer' -> {id: {orders, bookings}};  kind = 'vendor' (ids are vendor_profiles.id) -> {id: {products, orders, bookings}}
create or replace function public.admin_entity_counts(p_kind text, p_ids uuid[])
returns jsonb language sql stable security definer set search_path = ''
as $$
  select case p_kind
    when 'customer' then coalesce((select jsonb_object_agg(i, jsonb_build_object(
        'orders',   (select count(*) from public.orders where customer_id = i),
        'bookings', (select count(*) from public.service_bookings where customer_id = i))) from unnest(p_ids) i), '{}'::jsonb)
    when 'vendor' then coalesce((select jsonb_object_agg(i, jsonb_build_object(
        'products', (select count(*) from public.products where vendor_id = i),
        'orders',   (select count(*) from public.vendor_orders where vendor_id = i and released_at is not null),
        'bookings', (select count(*) from public.service_bookings where vendor_id = i))) from unnest(p_ids) i), '{}'::jsonb)
    else '{}'::jsonb end;
$$;

revoke execute on function public.admin_dashboard_summary(date, date), public.admin_entity_counts(text, uuid[]) from public, anon, authenticated;
grant execute on function public.admin_dashboard_summary(date, date), public.admin_entity_counts(text, uuid[]) to service_role;
