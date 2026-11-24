-- 14: transactional order/payment/refund functions (PL/pgSQL).
--
-- WHY FUNCTIONS: PostgREST executes one statement per request. Checkout (stock + order + payment + coupon + cart) and every
-- status change that touches stock/money must be ONE transaction, so they live here. They are SECURITY DEFINER and executable
-- by service_role ONLY: the FastAPI backend authenticates/authorises the caller first and passes the actor explicitly.
-- Business errors are raised as  'CM:<code>:<detail>'  (SQLSTATE P0001) and translated by the backend.
--
-- LOCK ORDER (prevents deadlocks): order -> vendor order(s) -> payment -> refund. Every function takes locks in this order.
--
-- STOCK MODEL: stock is RESERVED (deducted) atomically when the order is created, under a row lock on each product.
-- It is given back exactly once (order_items.stock_restored_at) when the order/vendor order is cancelled or rejected,
-- or when an unpaid online order passes its payment deadline. Delivery does not touch stock again.

create or replace function public.cm_set_actor(p_actor uuid, p_role text, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform set_config('app.actor_id', coalesce(p_actor::text, ''), true);
  perform set_config('app.actor_role', coalesce(p_role, ''), true);
  perform set_config('app.status_note', coalesce(p_note, ''), true);
end;
$$;

create or replace function public.cm_notify(p_user uuid, p_type public.notification_type, p_title text, p_message text, p_related_type text, p_related_id uuid)
returns void language sql security definer set search_path = ''
as $$
  insert into public.notifications (user_id, type, title, message, related_type, related_id)
  select p_user, p_type, p_title, p_message, p_related_type, p_related_id where p_user is not null;
$$;

-- give reserved stock back, once per order item
create or replace function public.cm_restore_stock(p_vendor_order uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  for r in
    with restored as (
      update public.order_items set stock_restored_at = now()
       where vendor_order_id = p_vendor_order and stock_restored_at is null
      returning product_id, quantity)
    select product_id, sum(quantity)::int as qty from restored where product_id is not null group by product_id order by product_id
  loop
    update public.products set stock_quantity = stock_quantity + r.qty where id = r.product_id;
  end loop;
end;
$$;

-- refund record (requested). Locks the payment so concurrent requests cannot exceed the paid amount.
create or replace function public.cm_create_refund(p_payment uuid, p_amount numeric, p_reason text, p_actor uuid, p_vendor_order uuid, p_idem text, p_order uuid)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare pay public.payments; rid uuid; committed numeric;
begin
  select * into pay from public.payments where id = p_payment for update;
  if not found then raise exception 'CM:not_found:payment' using errcode = 'P0001'; end if;
  if p_idem is not null then
    select id into rid from public.refunds where idempotency_key = p_idem;
    if found then return rid; end if;
  end if;
  if pay.status not in ('successful', 'partially_refunded') then
    raise exception 'CM:payment_not_refundable:%', pay.status using errcode = 'P0001';
  end if;
  select coalesce(sum(amount), 0) into committed from public.refunds where payment_id = p_payment and status in ('requested', 'approved', 'processed');
  if p_amount is null or p_amount <= 0 then raise exception 'CM:invalid_amount:' using errcode = 'P0001'; end if;
  if committed + p_amount > pay.amount then
    raise exception 'CM:refund_exceeds:%', (pay.amount - committed) using errcode = 'P0001';
  end if;
  insert into public.refunds (payment_id, order_id, vendor_order_id, amount, reason, status, requested_by, idempotency_key, provider)
  values (p_payment, coalesce(p_order, pay.order_id), p_vendor_order, p_amount, p_reason, 'requested', p_actor, p_idem, pay.provider)
  returning id into rid;
  return rid;
end;
$$;

-- reject/cancel ONE vendor order: status, stock, refund request (if already paid) or COD amount adjustment
create or replace function public.cm_cancel_vendor_order(p_vo uuid, p_status public.vendor_order_status, p_actor uuid, p_role text, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare vo public.vendor_orders; o public.orders; pay public.payments;
begin
  select * into vo from public.vendor_orders where id = p_vo for update;
  if vo.status in ('rejected', 'cancelled', 'delivered') then
    raise exception 'CM:invalid_transition:%>%', vo.status, p_status using errcode = 'P0001';
  end if;
  update public.vendor_orders
     set status = p_status,
         rejection_reason = case when p_status = 'rejected' then p_reason else rejection_reason end,
         cancellation_reason = case when p_status = 'cancelled' then p_reason else cancellation_reason end,
         cancelled_at = now(), cancelled_by = p_actor
   where id = p_vo;
  perform public.cm_restore_stock(p_vo);

  select * into o from public.orders where id = vo.order_id;
  select * into pay from public.payments where order_id = o.id and status in ('successful', 'partially_refunded') order by paid_at limit 1;
  if found then
    perform public.cm_create_refund(pay.id, vo.total_amount,
            'Vendor order ' || vo.vendor_order_number || ' ' || p_status::text || coalesce(': ' || p_reason, ''), p_actor, vo.id, 'vo-cancel:' || vo.id, o.id);
  else
    -- cash not yet collected: the customer simply owes less
    update public.payments set amount = greatest(amount - vo.total_amount, 0)
     where order_id = o.id and method = 'cod' and status = 'pending';
  end if;

  perform public.cm_notify(o.customer_id, 'order',
         'Order ' || p_status::text, 'Part of order ' || o.order_number || ' was ' || p_status::text || coalesce(' (' || p_reason || ')', '') || '.', 'order', o.id);
end;
$$;

-- after any vendor-order change: cancel the parent when nothing is left, complete it when everything is delivered
create or replace function public.cm_finalize_order(p_order uuid, p_actor uuid, p_role text, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare o public.orders; total int; inactive int; delivered int;
begin
  select * into o from public.orders where id = p_order for update;
  if o.status in ('cancelled', 'completed') then return; end if;
  select count(*), count(*) filter (where status in ('rejected', 'cancelled')), count(*) filter (where status = 'delivered')
    into total, inactive, delivered from public.vendor_orders where order_id = p_order;
  if total > 0 and inactive = total then
    update public.orders
       set status = 'cancelled', cancelled_at = now(), cancelled_by = p_actor, cancelled_by_role = nullif(p_role, ''),
           cancelled_reason = coalesce(p_reason, cancelled_reason, 'All vendor orders were cancelled'),
           payment_status = case when payment_status in ('pending', 'processing', 'failed') then 'cancelled' else payment_status end
     where id = p_order;
    update public.payments set status = 'cancelled' where order_id = p_order and status in ('pending', 'processing');
    if o.coupon_id is not null then
      update public.coupons set used_count = greatest(used_count - 1, 0) where id = o.coupon_id;
    end if;
  elsif delivered > 0 and inactive + delivered = total then
    update public.orders set status = 'completed' where id = p_order;
    perform public.cm_notify(o.customer_id, 'order', 'Order completed', 'Order ' || o.order_number || ' has been delivered.', 'order', o.id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- CHECKOUT: validates under row locks, reserves stock, creates order + vendor orders + items + payment, consumes coupon,
-- removes the purchased lines from the cart. Idempotent per (customer, key).
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.place_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_customer uuid := (p ->> 'customer_id')::uuid;
  v_key text := p ->> 'idempotency_key';
  v_cod boolean := (p ->> 'payment_method') = 'cod';
  v_existing public.orders;
  v_prod public.products;
  v_coupon public.coupons;
  rec record; vo jsonb; it jsonb;
  v_order uuid; v_vo uuid; v_pay uuid; v_order_no text;
  v_qty int; v_sub numeric := 0; v_vsub numeric; v_tot_vo numeric := 0; v_del_vo numeric := 0; v_disc_vo numeric := 0; v_total_vo numeric := 0;
  v_product_ids uuid[] := '{}';
begin
  if v_key is null or length(v_key) < 8 then raise exception 'CM:idempotency_key_required:' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_customer::text || ':' || v_key, 0));
  perform public.cm_set_actor(v_customer, 'customer', null);

  select * into v_existing from public.orders where customer_id = v_customer and idempotency_key = v_key;
  if found then
    if v_existing.request_hash is distinct from (p ->> 'request_hash') then
      raise exception 'CM:idempotency_key_reuse:' using errcode = 'P0001';
    end if;
    select id into v_pay from public.payments where order_id = v_existing.id order by created_at desc limit 1;
    return jsonb_build_object('order_id', v_existing.id, 'order_number', v_existing.order_number, 'payment_id', v_pay, 'replay', true);
  end if;

  -- lock + validate every product, in a stable order (no deadlocks between concurrent checkouts)
  for rec in
    select (v.value ->> 'vendor_id')::uuid as vendor_id, i.value as item
      from jsonb_array_elements(p -> 'vendor_orders') as v(value), jsonb_array_elements(v.value -> 'items') as i(value)
     order by i.value ->> 'product_id'
  loop
    v_qty := (rec.item ->> 'quantity')::int;
    if v_qty is null or v_qty <= 0 then raise exception 'CM:invalid_quantity:%', rec.item ->> 'product_id' using errcode = 'P0001'; end if;
    select * into v_prod from public.products where id = (rec.item ->> 'product_id')::uuid for update;
    if not found then raise exception 'CM:product_unavailable:%', rec.item ->> 'product_id' using errcode = 'P0001'; end if;
    if v_prod.vendor_id <> rec.vendor_id then raise exception 'CM:invalid_vendor:%', v_prod.id using errcode = 'P0001'; end if;
    if not v_prod.is_active or v_prod.approval_status <> 'approved' or not v_prod.is_available then
      raise exception 'CM:product_unavailable:%', v_prod.id using errcode = 'P0001';
    end if;
    if not public.vendor_is_approved(v_prod.vendor_id) then raise exception 'CM:vendor_unavailable:%', v_prod.vendor_id using errcode = 'P0001'; end if;
    if v_prod.price <> (rec.item ->> 'unit_price')::numeric then raise exception 'CM:price_changed:%', v_prod.id using errcode = 'P0001'; end if;
    if v_prod.stock_quantity < v_qty then raise exception 'CM:insufficient_stock:%', v_prod.id using errcode = 'P0001'; end if;
    update public.products set stock_quantity = stock_quantity - v_qty where id = v_prod.id;
    if v_prod.id = any (v_product_ids) then raise exception 'CM:duplicate_product:%', v_prod.id using errcode = 'P0001'; end if;
    v_product_ids := v_product_ids || v_prod.id;
    v_sub := v_sub + v_prod.price * v_qty;
  end loop;
  if array_length(v_product_ids, 1) is null then raise exception 'CM:empty_cart:' using errcode = 'P0001'; end if;
  if v_sub <> (p ->> 'subtotal')::numeric then raise exception 'CM:totals_mismatch:subtotal' using errcode = 'P0001'; end if;
  if (p ->> 'total_amount')::numeric <= 0 then raise exception 'CM:invalid_total:' using errcode = 'P0001'; end if;

  -- coupon: consume one use atomically
  if nullif(p ->> 'coupon_id', '') is not null then
    update public.coupons set used_count = used_count + 1
     where id = (p ->> 'coupon_id')::uuid and is_active and valid_from <= now() and (valid_until is null or valid_until > now())
       and (usage_limit is null or used_count < usage_limit)
    returning * into v_coupon;
    if not found then raise exception 'CM:coupon_unavailable:%', p ->> 'coupon_code' using errcode = 'P0001'; end if;
    if v_coupon.per_user_limit is not null and
       (select count(*) from public.orders where customer_id = v_customer and coupon_id = v_coupon.id and status <> 'cancelled') >= v_coupon.per_user_limit then
      raise exception 'CM:coupon_unavailable:%', p ->> 'coupon_code' using errcode = 'P0001';
    end if;
  end if;

  insert into public.orders (customer_id, status, payment_method, payment_status, delivery_address_id, delivery_address,
                             subtotal, delivery_charge, discount_amount, total_amount, coupon_id, coupon_code, customer_note,
                             idempotency_key, request_hash, payment_due_at)
  values (v_customer, (case when v_cod then 'confirmed' else 'pending' end)::public.order_status, (p ->> 'payment_method')::public.payment_method, 'pending',
          nullif(p ->> 'delivery_address_id', '')::uuid, p -> 'delivery_address',
          (p ->> 'subtotal')::numeric, (p ->> 'delivery_charge')::numeric, (p ->> 'discount_amount')::numeric, (p ->> 'total_amount')::numeric,
          nullif(p ->> 'coupon_id', '')::uuid, nullif(p ->> 'coupon_code', ''), nullif(p ->> 'customer_note', ''),
          v_key, p ->> 'request_hash', case when v_cod then null else nullif(p ->> 'payment_due_at', '')::timestamptz end)
  returning id, order_number into v_order, v_order_no;

  for vo in select value from jsonb_array_elements(p -> 'vendor_orders') loop
    v_vsub := 0;
    insert into public.vendor_orders (order_id, vendor_id, vendor_name, status, subtotal, delivery_charge, discount_amount, total_amount,
                                      commission_rule_id, commission_amount, released_at)
    values (v_order, (vo ->> 'vendor_id')::uuid, vo ->> 'vendor_name', 'pending', (vo ->> 'subtotal')::numeric, (vo ->> 'delivery_charge')::numeric,
            (vo ->> 'discount_amount')::numeric, (vo ->> 'total_amount')::numeric, nullif(vo ->> 'commission_rule_id', '')::uuid,
            (vo ->> 'commission_amount')::numeric, case when v_cod then now() end)
    returning id into v_vo;
    for it in select value from jsonb_array_elements(vo -> 'items') loop
      insert into public.order_items (order_id, vendor_order_id, product_id, product_name, product_brand, product_model, product_condition,
                                      product_image_path, unit_price, quantity, line_total, commission_rule_id, commission_amount)
      values (v_order, v_vo, (it ->> 'product_id')::uuid, it ->> 'name', it ->> 'brand', it ->> 'model', (it ->> 'condition')::public.product_condition,
              it ->> 'image_path', (it ->> 'unit_price')::numeric, (it ->> 'quantity')::int,
              (it ->> 'unit_price')::numeric * (it ->> 'quantity')::int, nullif(it ->> 'commission_rule_id', '')::uuid, (it ->> 'commission_amount')::numeric);
      v_vsub := v_vsub + (it ->> 'unit_price')::numeric * (it ->> 'quantity')::int;
    end loop;
    if v_vsub <> (vo ->> 'subtotal')::numeric then raise exception 'CM:totals_mismatch:vendor_order' using errcode = 'P0001'; end if;
    v_tot_vo := v_tot_vo + (vo ->> 'subtotal')::numeric;
    v_del_vo := v_del_vo + (vo ->> 'delivery_charge')::numeric;
    v_disc_vo := v_disc_vo + (vo ->> 'discount_amount')::numeric;
    v_total_vo := v_total_vo + (vo ->> 'total_amount')::numeric;
    if v_cod then
      perform public.cm_notify((select user_id from public.vendor_profiles where id = (vo ->> 'vendor_id')::uuid), 'order',
              'New order', 'New order ' || v_order_no || ' is waiting for your response.', 'vendor_order', v_vo);
    end if;
  end loop;
  if v_tot_vo <> (p ->> 'subtotal')::numeric or v_del_vo <> (p ->> 'delivery_charge')::numeric
     or v_disc_vo <> (p ->> 'discount_amount')::numeric or v_total_vo <> (p ->> 'total_amount')::numeric then
    raise exception 'CM:totals_mismatch:order' using errcode = 'P0001';
  end if;

  insert into public.payments (customer_id, order_id, method, provider, amount, currency, status)
  values (v_customer, v_order, (p ->> 'payment_method')::public.payment_method, case when v_cod then null else nullif(p ->> 'provider', '') end,
          (p ->> 'total_amount')::numeric, coalesce(p ->> 'currency', 'INR'), 'pending')
  returning id into v_pay;

  delete from public.cart_items
   where cart_id = (select id from public.carts where user_id = v_customer) and product_id = any (v_product_ids);

  perform public.cm_notify(v_customer, 'order', 'Order placed',
          'Order ' || v_order_no || case when v_cod then ' is confirmed (cash on delivery).' else ' is waiting for payment.' end, 'order', v_order);

  return jsonb_build_object('order_id', v_order, 'order_number', v_order_no, 'payment_id', v_pay, 'replay', false);
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- CANCELLATION (customer / admin / system)
-- customer: only while every vendor order is still pending or accepted (nothing prepared yet). admin/system: any active one.
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.cancel_order(p_order uuid, p_actor uuid, p_role text, p_reason text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare o public.orders; v record; n int := 0;
begin
  perform public.cm_set_actor(p_actor, p_role, p_reason);
  select * into o from public.orders where id = p_order for update;
  if not found or (p_role = 'customer' and o.customer_id is distinct from p_actor) then
    raise exception 'CM:not_found:order' using errcode = 'P0001';
  end if;
  if o.status in ('cancelled', 'completed') then raise exception 'CM:not_cancellable:%', o.status using errcode = 'P0001'; end if;
  if p_role = 'customer' and exists (select 1 from public.vendor_orders where order_id = p_order and status not in ('pending', 'accepted', 'rejected', 'cancelled')) then
    raise exception 'CM:not_cancellable:preparation_started' using errcode = 'P0001';
  end if;
  for v in select id from public.vendor_orders
            where order_id = p_order and status in ('pending', 'accepted', 'preparing', 'ready_for_dispatch', 'out_for_delivery') order by id loop
    perform public.cm_cancel_vendor_order(v.id, 'cancelled', p_actor, p_role, p_reason);
    n := n + 1;
  end loop;
  perform public.cm_finalize_order(p_order, p_actor, p_role, p_reason);
  return jsonb_build_object('order_id', p_order, 'vendor_orders_cancelled', n);
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- VENDOR ORDER STATE MACHINE.   pending -> accepted -> preparing -> ready_for_dispatch -> out_for_delivery -> delivered
--   reject: pending only.  cancel: accepted/preparing/ready_for_dispatch (vendor) or any active state (admin).
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.transition_vendor_order(p_vo uuid, p_vendor uuid, p_status public.vendor_order_status, p_actor uuid, p_role text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare vo public.vendor_orders; o public.orders; ok boolean;
begin
  perform public.cm_set_actor(p_actor, p_role, p_note);
  select * into vo from public.vendor_orders where id = p_vo;
  if not found or (p_vendor is not null and vo.vendor_id <> p_vendor) then raise exception 'CM:not_found:vendor_order' using errcode = 'P0001'; end if;
  select * into o from public.orders where id = vo.order_id for update;       -- order first (lock order)
  select * into vo from public.vendor_orders where id = p_vo for update;
  if o.status = 'cancelled' or vo.released_at is null then raise exception 'CM:order_not_active:%', o.status using errcode = 'P0001'; end if;

  if p_status = 'rejected' then
    if vo.status <> 'pending' then raise exception 'CM:invalid_transition:%>%', vo.status, p_status using errcode = 'P0001'; end if;
    perform public.cm_cancel_vendor_order(p_vo, 'rejected', p_actor, p_role, p_note);
  elsif p_status = 'cancelled' then
    ok := vo.status in ('pending', 'accepted', 'preparing', 'ready_for_dispatch') or (p_role = 'admin' and vo.status = 'out_for_delivery');
    if not ok then raise exception 'CM:invalid_transition:%>%', vo.status, p_status using errcode = 'P0001'; end if;
    perform public.cm_cancel_vendor_order(p_vo, 'cancelled', p_actor, p_role, p_note);
  else
    ok := (vo.status = 'pending' and p_status = 'accepted') or (vo.status = 'accepted' and p_status = 'preparing')
       or (vo.status = 'preparing' and p_status = 'ready_for_dispatch')
       or (vo.status = 'ready_for_dispatch' and p_status in ('out_for_delivery', 'delivered'))
       or (vo.status = 'out_for_delivery' and p_status = 'delivered');
    if not ok then raise exception 'CM:invalid_transition:%>%', vo.status, p_status using errcode = 'P0001'; end if;
    update public.vendor_orders set status = p_status, vendor_note = coalesce(nullif(p_note, ''), vendor_note) where id = p_vo;
    if p_status = 'delivered' then
      insert into public.vendor_settlements (vendor_id, vendor_order_id, gross_amount, commission_amount, deductions_amount, net_amount, status)
      values (vo.vendor_id, vo.id, vo.subtotal, vo.commission_amount, 0, vo.subtotal - coalesce(vo.commission_amount, 0),
              (case when o.payment_status in ('successful', 'partially_refunded') then 'ready' else 'pending' end)::public.settlement_status)
      on conflict (vendor_order_id) do nothing;
    end if;
    perform public.cm_notify(o.customer_id, 'order', 'Order ' || replace(p_status::text, '_', ' '),
            'Order ' || o.order_number || ' is now ' || replace(p_status::text, '_', ' ') || '.', 'order', o.id);
  end if;
  perform public.cm_finalize_order(o.id, p_actor, p_role, p_note);
  return jsonb_build_object('vendor_order_id', p_vo, 'status', (select status from public.vendor_orders where id = p_vo));
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- PAYMENT EVENTS (verified by the backend before this is called). Idempotent per (provider, event_id).
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.apply_payment_event(p jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  ev uuid; pay public.payments; o public.orders; rf public.refunds; v_outcome text := 'ignored';
  v_amount numeric := nullif(p ->> 'amount', '')::numeric; v_type text := p ->> 'event_type'; dup boolean; rid uuid;
begin
  insert into public.payment_events (provider, event_id, event_type, provider_order_id, provider_payment_id, amount, currency)
  values (p ->> 'provider', p ->> 'event_id', v_type, nullif(p ->> 'provider_order_id', ''), nullif(p ->> 'provider_payment_id', ''), v_amount, p ->> 'currency')
  on conflict (provider, event_id) do nothing returning id into ev;
  if ev is null then return jsonb_build_object('outcome', 'duplicate'); end if;

  -- refund confirmations from the provider
  if v_type like 'refund.%' then
    select * into rf from public.refunds
     where provider_refund_id = nullif(p ->> 'provider_refund_id', '') and (provider is null or provider = p ->> 'provider')
     order by created_at desc limit 1;
    if not found then
      update public.payment_events set outcome = 'unmatched' where id = ev;
      return jsonb_build_object('outcome', 'unmatched');
    end if;
    if v_type = 'refund.processed' and rf.status = 'approved' then
      perform public.apply_refund_result(rf.id, 'processed', null, rf.provider_refund_id, null, 'provider webhook');
      v_outcome := 'applied';
    elsif v_type = 'refund.failed' and rf.status = 'approved' then
      perform public.apply_refund_result(rf.id, 'failed', null, null, coalesce(nullif(p ->> 'failure_reason', ''), 'Provider reported a failure'), 'provider webhook');
      v_outcome := 'applied';
    end if;
    update public.payment_events set outcome = v_outcome, payment_id = rf.payment_id where id = ev;
    return jsonb_build_object('outcome', v_outcome, 'refund_id', rf.id);
  end if;

  select * into pay from public.payments
   where provider = p ->> 'provider'
     and ((nullif(p ->> 'provider_order_id', '') is not null and provider_order_id = p ->> 'provider_order_id')
       or (nullif(p ->> 'provider_payment_id', '') is not null and provider_payment_id = p ->> 'provider_payment_id'))
   order by created_at desc limit 1;
  if not found then
    update public.payment_events set outcome = 'unmatched' where id = ev;
    return jsonb_build_object('outcome', 'unmatched');
  end if;
  update public.payment_events set payment_id = pay.id where id = ev;
  select * into o from public.orders where id = pay.order_id for update;      -- order first (lock order)
  select * into pay from public.payments where id = pay.id for update;
  perform public.cm_set_actor(null, 'system', 'payment ' || v_type);

  if v_type = 'payment.succeeded' then
    if pay.status in ('successful', 'partially_refunded', 'refunded') then
      v_outcome := 'already_applied';
    elsif v_amount is distinct from pay.amount or upper(coalesce(p ->> 'currency', pay.currency)) <> upper(pay.currency) then
      update public.payments set needs_review = true,
             review_reason = 'Provider reported ' || coalesce(v_amount::text, '?') || ' ' || coalesce(p ->> 'currency', '?') || ' but ' || pay.amount || ' ' || pay.currency || ' was expected'
       where id = pay.id;
      v_outcome := 'amount_mismatch';
    else
      update public.payments set status = 'cancelled' where order_id = pay.order_id and id <> pay.id and status in ('pending', 'processing');
      dup := exists (select 1 from public.payments where order_id = pay.order_id and id <> pay.id and status in ('successful', 'partially_refunded', 'refunded'));
      update public.payments set status = 'successful', paid_at = now(), failure_reason = null,
             provider_payment_id = coalesce(nullif(p ->> 'provider_payment_id', ''), provider_payment_id),
             needs_review = dup or o.status = 'cancelled',
             review_reason = case when dup then 'Duplicate payment for the same order' when o.status = 'cancelled' then 'Payment received after the order was cancelled' end
       where id = pay.id;
      update public.orders set payment_status = 'successful' where id = o.id;
      if dup then
        rid := public.cm_create_refund(pay.id, pay.amount, 'Duplicate payment for order ' || o.order_number, null, null, 'dup-payment:' || pay.id, o.id);
        v_outcome := 'applied_duplicate_refund_requested';
      elsif o.status = 'cancelled' then
        rid := public.cm_create_refund(pay.id, pay.amount, 'Payment received after order ' || o.order_number || ' was cancelled', null, null, 'late-payment:' || pay.id, o.id);
        v_outcome := 'applied_late_refund_requested';
      else
        update public.orders set status = 'confirmed' where id = o.id and status = 'pending';
        update public.vendor_orders set released_at = now() where order_id = o.id and released_at is null and status = 'pending';
        perform public.cm_notify(o.customer_id, 'payment', 'Payment received', 'We received your payment for order ' || o.order_number || '.', 'order', o.id);
        perform public.cm_notify(vp.user_id, 'order', 'New order', 'New order ' || o.order_number || ' is waiting for your response.', 'vendor_order', vo.id)
           from public.vendor_orders vo join public.vendor_profiles vp on vp.id = vo.vendor_id where vo.order_id = o.id and vo.status = 'pending';
        v_outcome := 'applied';
      end if;
    end if;
  elsif v_type = 'payment.failed' then
    if pay.status in ('pending', 'processing') then
      update public.payments set status = 'failed', failure_reason = nullif(p ->> 'failure_reason', '') where id = pay.id;
      update public.orders set payment_status = 'failed' where id = o.id and status = 'pending';
      perform public.cm_notify(o.customer_id, 'payment', 'Payment failed', 'Payment for order ' || o.order_number || ' did not go through. You can retry.', 'order', o.id);
      v_outcome := 'applied';
    end if;
  elsif v_type = 'payment.processing' then
    if pay.status = 'pending' then
      update public.payments set status = 'processing' where id = pay.id;
      update public.orders set payment_status = 'processing' where id = o.id and status = 'pending';
      v_outcome := 'applied';
    end if;
  elsif v_type = 'payment.cancelled' then
    if pay.status in ('pending', 'processing') then
      update public.payments set status = 'cancelled' where id = pay.id;
      update public.orders set payment_status = 'cancelled' where id = o.id and status = 'pending';
      v_outcome := 'applied';
    end if;
  end if;
  update public.payment_events set outcome = v_outcome where id = ev;
  return jsonb_build_object('outcome', v_outcome, 'payment_id', pay.id, 'order_id', o.id);
end;
$$;

-- attach the provider's order reference to a payment attempt (called right after the provider accepts the request)
create or replace function public.attach_provider_order(p_payment uuid, p_provider text, p_provider_order_id text)
returns void language sql security definer set search_path = ''
as $$
  update public.payments set provider = p_provider, provider_order_id = p_provider_order_id, status = 'processing'
   where id = p_payment and status = 'pending' and method = 'online';
  update public.orders set payment_status = 'processing'
   where id = (select order_id from public.payments where id = p_payment) and status = 'pending';
$$;

-- new online attempt for an unpaid order (retry). Closes nothing: the unique index guarantees one open attempt.
create or replace function public.new_payment_attempt(p_order uuid, p_customer uuid, p_provider text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare o public.orders; pid uuid;
begin
  select * into o from public.orders where id = p_order and customer_id = p_customer for update;
  if not found then raise exception 'CM:not_found:order' using errcode = 'P0001'; end if;
  if o.payment_method <> 'online' then raise exception 'CM:not_online_order:' using errcode = 'P0001'; end if;
  if o.status <> 'pending' or o.payment_status = 'successful' then raise exception 'CM:order_not_payable:%', o.status using errcode = 'P0001'; end if;
  if o.payment_due_at is not null and o.payment_due_at < now() then raise exception 'CM:payment_window_expired:' using errcode = 'P0001'; end if;
  select id into pid from public.payments where order_id = p_order and status in ('pending', 'processing');
  if found then return pid; end if;
  insert into public.payments (customer_id, order_id, method, provider, amount, currency, status)
  values (p_customer, p_order, 'online', p_provider, o.total_amount, coalesce((select currency from public.payments where order_id = p_order order by created_at limit 1), 'INR'), 'pending')
  returning id into pid;
  update public.orders set payment_status = 'pending' where id = p_order;
  return pid;
end;
$$;

-- COD cash collection recorded by an administrator
create or replace function public.record_cod_collection(p_payment uuid, p_admin uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare pay public.payments; o public.orders;
begin
  perform public.cm_set_actor(p_admin, 'admin', 'COD collected');
  select * into pay from public.payments where id = p_payment;
  if not found then raise exception 'CM:not_found:payment' using errcode = 'P0001'; end if;
  select * into o from public.orders where id = pay.order_id for update;      -- order first (lock order)
  select * into pay from public.payments where id = p_payment for update;
  if pay.method <> 'cod' or pay.status <> 'pending' then raise exception 'CM:not_collectable:%', pay.status using errcode = 'P0001'; end if;
  if o.status not in ('confirmed', 'completed') then raise exception 'CM:order_not_active:%', o.status using errcode = 'P0001'; end if;
  if not exists (select 1 from public.vendor_orders where order_id = o.id and status in ('out_for_delivery', 'delivered')) then
    raise exception 'CM:not_dispatched:' using errcode = 'P0001';
  end if;
  update public.payments set status = 'successful', paid_at = now(), recorded_by = p_admin where id = p_payment;
  update public.orders set payment_status = 'successful' where id = o.id;
  update public.vendor_settlements set status = 'ready'
   where status = 'pending' and vendor_order_id in (select id from public.vendor_orders where order_id = o.id);
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, details)
  values (p_admin, 'admin', 'cod_collected', 'payment', p_payment, jsonb_build_object('order_id', o.id, 'amount', pay.amount));
  perform public.cm_notify(o.customer_id, 'payment', 'Payment received', 'Cash payment for order ' || o.order_number || ' was recorded.', 'order', o.id);
  return jsonb_build_object('payment_id', p_payment, 'order_id', o.id, 'status', 'successful');
end;
$$;

-- REFUND lifecycle: requested -> approved -> processed | failed | rejected.  'processed' only via this function.
create or replace function public.apply_refund_result(p_refund uuid, p_status public.refund_status, p_actor uuid, p_provider_refund_id text, p_failure_reason text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare r public.refunds; pay public.payments; new_refunded numeric; new_status public.payment_status; ok boolean;
begin
  perform public.cm_set_actor(p_actor, 'admin', p_note);
  select * into r from public.refunds where id = p_refund;
  if not found then raise exception 'CM:not_found:refund' using errcode = 'P0001'; end if;
  select * into pay from public.payments where id = r.payment_id;
  perform 1 from public.orders where id = pay.order_id for update;           -- order first (lock order)
  select * into pay from public.payments where id = r.payment_id for update;
  select * into r from public.refunds where id = p_refund for update;
  ok := (r.status = 'requested' and p_status in ('approved', 'rejected'))
     or (r.status = 'approved' and p_status in ('processed', 'failed', 'rejected'))
     or (r.status = 'failed' and p_status = 'approved');
  if not ok then raise exception 'CM:invalid_transition:%>%', r.status, p_status using errcode = 'P0001'; end if;

  update public.refunds
     set status = p_status, provider_refund_id = coalesce(nullif(p_provider_refund_id, ''), provider_refund_id),
         failure_reason = case when p_status = 'failed' then p_failure_reason else null end,
         processed_by = case when p_status in ('processed', 'rejected', 'approved') then p_actor else processed_by end,
         processed_at = case when p_status = 'processed' then now() else processed_at end
   where id = p_refund;

  if p_status = 'processed' then
    new_refunded := pay.refunded_amount + r.amount;
    new_status := (case when new_refunded >= pay.amount then 'refunded' else 'partially_refunded' end)::public.payment_status;
    update public.payments set refunded_amount = new_refunded, status = new_status where id = pay.id;
    update public.orders set payment_status = new_status where id = pay.order_id;
    -- refund of a delivered vendor order reduces what the vendor is owed
    update public.vendor_settlements
       set deductions_amount = deductions_amount + r.amount, net_amount = net_amount - r.amount
     where vendor_order_id = r.vendor_order_id and r.vendor_order_id is not null;
  end if;
  if p_status = 'processed' then
    perform public.cm_notify(pay.customer_id, 'payment', 'Refund processed', 'A refund of ' || r.amount || ' ' || pay.currency || ' was processed.', 'payment', pay.id);
  end if;
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, details)
  values (p_actor, case when p_actor is null then 'system' else 'admin' end, 'refund_' || p_status::text, 'refund', p_refund, jsonb_build_object('amount', r.amount, 'payment_id', r.payment_id, 'note', p_note));
  return jsonb_build_object('refund_id', p_refund, 'status', p_status);
end;
$$;

-- cancel unpaid online orders past their payment deadline and return their stock (call from a scheduler)
create or replace function public.expire_unpaid_orders(p_limit int default 100)
returns int language plpgsql security definer set search_path = ''
as $$
declare v record; n int := 0;
begin
  for v in select id from public.orders
            where status = 'pending' and payment_method = 'online' and payment_due_at is not null and payment_due_at < now()
              and not exists (select 1 from public.payments where order_id = orders.id and status in ('successful', 'partially_refunded', 'refunded'))
            order by payment_due_at limit p_limit for update skip locked loop
    perform public.cancel_order(v.id, null, 'system', 'Payment was not received in time');
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function public.platform_revenue(p_from timestamptz, p_to timestamptz)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'collected', coalesce((select sum(amount) from public.payments where status in ('successful', 'partially_refunded', 'refunded') and paid_at >= p_from and paid_at < p_to), 0),
    'refunded', coalesce((select sum(amount) from public.refunds where status = 'processed' and processed_at >= p_from and processed_at < p_to), 0),
    'commission_earned', coalesce((select sum(commission_amount) from public.vendor_orders where status = 'delivered' and delivered_at >= p_from and delivered_at < p_to), 0),
    'cod_outstanding', coalesce((select sum(p.amount) from public.payments p join public.orders o on o.id = p.order_id where p.method = 'cod' and p.status = 'pending' and o.status in ('confirmed', 'completed')), 0),
    'orders_placed', (select count(*) from public.orders where created_at >= p_from and created_at < p_to),
    'orders_completed', (select count(*) from public.orders where status = 'completed' and updated_at >= p_from and updated_at < p_to));
$$;

-- service_role only
revoke execute on function
  public.cm_set_actor(uuid, text, text), public.cm_notify(uuid, public.notification_type, text, text, text, uuid), public.cm_restore_stock(uuid),
  public.cm_create_refund(uuid, numeric, text, uuid, uuid, text, uuid), public.cm_cancel_vendor_order(uuid, public.vendor_order_status, uuid, text, text),
  public.cm_finalize_order(uuid, uuid, text, text), public.place_order(jsonb), public.cancel_order(uuid, uuid, text, text),
  public.transition_vendor_order(uuid, uuid, public.vendor_order_status, uuid, text, text), public.apply_payment_event(jsonb),
  public.attach_provider_order(uuid, text, text), public.new_payment_attempt(uuid, uuid, text), public.record_cod_collection(uuid, uuid),
  public.apply_refund_result(uuid, public.refund_status, uuid, text, text, text), public.expire_unpaid_orders(int), public.platform_revenue(timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function
  public.place_order(jsonb), public.cancel_order(uuid, uuid, text, text),
  public.transition_vendor_order(uuid, uuid, public.vendor_order_status, uuid, text, text), public.apply_payment_event(jsonb),
  public.attach_provider_order(uuid, text, text), public.new_payment_attempt(uuid, uuid, text), public.record_cod_collection(uuid, uuid),
  public.apply_refund_result(uuid, public.refund_status, uuid, text, text, text), public.expire_unpaid_orders(int), public.platform_revenue(timestamptz, timestamptz),
  public.cm_create_refund(uuid, numeric, text, uuid, uuid, text, uuid)
  to service_role;
