-- 17: read-only aggregate for the Vendor App dashboard / earnings screen (service_role only; the backend authorises first and passes the vendor id).
-- One round trip instead of the app paging through every order, booking and settlement. Nothing here writes data.
-- Money is exactly what the order/settlement records hold (commission is the snapshot taken at completion). No frontend maths.

create or replace function public.vendor_dashboard_summary(p_vendor uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'orders', jsonb_build_object(
      'total',      (select count(*) from public.vendor_orders where vendor_id = p_vendor and released_at is not null),
      'by_status',  coalesce((select jsonb_object_agg(status, n) from (
                        select status, count(*) n from public.vendor_orders where vendor_id = p_vendor and released_at is not null group by status) s), '{}'::jsonb),
      'sales_total',      coalesce((select sum(subtotal) from public.vendor_orders where vendor_id = p_vendor and status = 'delivered'), 0),
      'commission_total', coalesce((select sum(commission_amount) from public.vendor_orders where vendor_id = p_vendor and status = 'delivered'), 0)
    ),
    'products', jsonb_build_object(
      'total',            (select count(*) from public.products where vendor_id = p_vendor),
      'active',           (select count(*) from public.products where vendor_id = p_vendor and is_active and approval_status = 'approved'),
      'pending_approval', (select count(*) from public.products where vendor_id = p_vendor and approval_status = 'pending'),
      'rejected',         (select count(*) from public.products where vendor_id = p_vendor and approval_status = 'rejected'),
      'out_of_stock',     (select count(*) from public.products where vendor_id = p_vendor and stock_quantity = 0)
    ),
    'bookings', jsonb_build_object(
      'total',     (select count(*) from public.service_bookings where vendor_id = p_vendor),
      'by_status', coalesce((select jsonb_object_agg(status, n) from (
                        select status, count(*) n from public.service_bookings where vendor_id = p_vendor group by status) s), '{}'::jsonb),
      -- recorded value of completed work (estimate + recorded extra charges). NOT a payment: nothing is collected through the platform for services.
      'completed_value', coalesce((select sum(coalesce(final_price, estimated_price)) from public.service_bookings where vendor_id = p_vendor and status = 'completed'), 0)
    ),
    'settlements', coalesce((select jsonb_object_agg(status, jsonb_build_object('count', n, 'gross', gross, 'commission', commission, 'deductions', deductions, 'net', net)) from (
                        select status, count(*) n, sum(gross_amount) gross, sum(commission_amount) commission, sum(deductions_amount) deductions, sum(net_amount) net
                        from public.vendor_settlements where vendor_id = p_vendor group by status) s), '{}'::jsonb)
  );
$$;

revoke execute on function public.vendor_dashboard_summary(uuid) from public, anon, authenticated;
grant execute on function public.vendor_dashboard_summary(uuid) to service_role;
