-- Behavioural tests of the Step 5 SQL functions. Prints "PASS <label>" / "FAIL <label>" lines. Run as superuser on a DB with all
-- migrations applied. Uses only data it creates itself.
\set ON_ERROR_STOP off
\pset tuples_only on
\pset format unaligned

create or replace function pg_temp.ck(label text, cond boolean) returns text language sql as $$ select case when coalesce(cond,false) then 'PASS ' else 'FAIL ' end || label $$;
-- run a statement that must fail with a CM:<code> business error
create or replace function pg_temp.err(label text, stmt text, code text) returns text language plpgsql as $$
begin
  execute stmt;
  return 'FAIL ' || label || ' (no error)';
exception when others then
  return case when sqlerrm like 'CM:' || code || '%' or sqlerrm like '%' || code || '%' then 'PASS ' else 'FAIL ' end || label || case when sqlerrm like '%'||code||'%' then '' else ' (got: ' || sqlerrm || ')' end;
end $$;

create or replace function pg_temp.vend(p_vendor uuid, p_items jsonb, p_delivery numeric default 0, p_discount numeric default 0, p_commission numeric default 0) returns jsonb language plpgsql as $$
declare sub numeric := 0; it jsonb; items jsonb := '[]'; begin
  for it in select value from jsonb_array_elements(p_items) loop
    sub := sub + (it->>'unit_price')::numeric * (it->>'quantity')::int;
    items := items || jsonb_build_array(it || jsonb_build_object('name','P','condition','new','commission_amount', round(((it->>'unit_price')::numeric * (it->>'quantity')::int) * p_commission / 100, 2)));
  end loop;
  return jsonb_build_object('vendor_id', p_vendor, 'vendor_name', 'V', 'subtotal', sub, 'delivery_charge', p_delivery, 'discount_amount', p_discount, 'total_amount', sub + p_delivery - p_discount,
     'commission_amount', round(sub * p_commission / 100, 2), 'items', items);
end $$;
create or replace function pg_temp.item(p_product uuid, p_price numeric, p_qty int) returns jsonb language sql as $$ select jsonb_build_object('product_id', p_product, 'unit_price', p_price, 'quantity', p_qty) $$;
create or replace function pg_temp.po(p_customer uuid, p_key text, p_method text, p_vendors jsonb, p_coupon uuid default null, p_hash text default 'h') returns jsonb language plpgsql as $$
declare v jsonb; s numeric := 0; d numeric := 0; x numeric := 0; t numeric := 0; begin
  for v in select value from jsonb_array_elements(p_vendors) loop
    s := s + (v->>'subtotal')::numeric; d := d + (v->>'delivery_charge')::numeric; x := x + (v->>'discount_amount')::numeric; t := t + (v->>'total_amount')::numeric; end loop;
  return jsonb_build_object('customer_id', p_customer, 'idempotency_key', p_key, 'request_hash', p_hash, 'payment_method', p_method,
    'delivery_address', jsonb_build_object('city','Pune'), 'subtotal', s, 'delivery_charge', d, 'discount_amount', x, 'total_amount', t,
    'coupon_id', p_coupon, 'coupon_code', case when p_coupon is null then null else 'SAVE' end, 'provider', case when p_method='online' then 'testpay' end,
    'currency', 'INR', 'payment_due_at', (now() + interval '30 minutes'), 'vendor_orders', p_vendors);
end $$;

create or replace function pg_temp.ev(p jsonb) returns text language plpgsql as $$ begin return public.apply_payment_event(p) ->> 'outcome'; end $$;
-- ---------- fixtures ----------
insert into auth.users (id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000a1','va@x.t','{"role":"vendor"}'),('00000000-0000-0000-0000-0000000000a2','vb@x.t','{"role":"vendor"}'),
 ('00000000-0000-0000-0000-0000000000c1','c1@x.t','{}'),('00000000-0000-0000-0000-0000000000c2','c2@x.t','{}'),('00000000-0000-0000-0000-0000000000ad','ad@x.t','{}');
update public.profiles set role='admin' where id='00000000-0000-0000-0000-0000000000ad';
insert into public.vendor_profiles (user_id,business_name,business_types,address_line1,city,state,postal_code,contact_phone,verification_status) values
 ('00000000-0000-0000-0000-0000000000a1','Alpha','{bicycle_shop}','a','Pune','MH','411001','+919800000001','approved'),
 ('00000000-0000-0000-0000-0000000000a2','Beta','{bicycle_shop}','a','Pune','MH','411001','+919800000002','approved');
create temp table fx as select
  (select id from public.vendor_profiles where business_name='Alpha') va, (select id from public.vendor_profiles where business_name='Beta') vb,
  (select id from public.categories where slug='new-cycles') cat;
insert into public.products (id,vendor_id,category_id,product_type,name,condition,price,stock_quantity,approval_status) select '10000000-0000-0000-0000-000000000001',va,cat,'new_cycle','Bike A','new',1000,5,'approved' from fx;
insert into public.products (id,vendor_id,category_id,product_type,name,condition,price,stock_quantity,approval_status) select '10000000-0000-0000-0000-000000000002',vb,cat,'new_cycle','Pads B','new',250.50,3,'approved' from fx;
insert into public.products (id,vendor_id,category_id,product_type,name,condition,price,stock_quantity,approval_status) select '10000000-0000-0000-0000-000000000003',va,cat,'new_cycle','Pending','new',10,5,'pending' from fx;
insert into public.coupons (id,code,discount_type,discount_value,usage_limit) values ('20000000-0000-0000-0000-000000000001','SAVE','fixed',100,1);
insert into public.carts (user_id) values ('00000000-0000-0000-0000-0000000000c1');
insert into public.cart_items (cart_id,product_id,quantity) select id,'10000000-0000-0000-0000-000000000001',2 from public.carts;
insert into public.cart_items (cart_id,product_id,quantity) select id,'10000000-0000-0000-0000-000000000002',1 from public.carts;

create or replace function pg_temp.stock(p uuid) returns int language sql as $$ select stock_quantity from public.products where id = p $$;
\set bike '10000000-0000-0000-0000-000000000001'
\set pads '10000000-0000-0000-0000-000000000002'
\set c1 '00000000-0000-0000-0000-0000000000c1'
\set c2 '00000000-0000-0000-0000-0000000000c2'
\set ad '00000000-0000-0000-0000-0000000000ad'

-- ================= COD checkout =================
select set_config('t.r1', public.place_order(pg_temp.po(:'c1', 'key-cod-0001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(:'bike', 1000, 2)), 50, 0, 10)))) ::text, false);
select pg_temp.ck('COD checkout reserves stock (5-2=3)', pg_temp.stock(:'bike') = 3);
select pg_temp.ck('COD order is confirmed with pending payment', (select status = 'confirmed' and payment_status = 'pending' and payment_due_at is null from public.orders));
select pg_temp.ck('COD vendor order released to vendor immediately', (select released_at is not null and status = 'pending' and vendor_name = 'V' and commission_amount = 200.00 from public.vendor_orders));
select pg_temp.ck('COD payment row: cod/pending/2050', (select method = 'cod' and status = 'pending' and amount = 2050 and provider is null from public.payments));
select pg_temp.ck('item snapshot + commission stored', (select unit_price = 1000 and quantity = 2 and line_total = 2000 and commission_amount = 200.00 and product_name = 'P' from public.order_items));
select pg_temp.ck('purchased cart line removed, other line kept', (select count(*) = 1 and min(product_id::text) = :'pads' from public.cart_items));
select pg_temp.ck('customer + vendor notified', (select count(*) filter (where user_id = :'c1') = 1 and count(*) filter (where user_id = '00000000-0000-0000-0000-0000000000a1') = 1 from public.notifications));
select pg_temp.ck('history rows carry the customer as actor', (select bool_and(changed_by = :'c1') from public.order_status_history));

-- idempotency
select set_config('t.r', (public.place_order(pg_temp.po(:'c1', 'key-cod-0001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(:'bike', 1000, 2)), 50, 0, 10)))) ->> 'replay'), false);
select pg_temp.ck('replay of same key returns same order, replay=true', current_setting('t.r') = 'true' and (select count(*) = 1 from public.orders));
select pg_temp.ck('replay did not deduct stock again', pg_temp.stock(:'bike') = 3);
select pg_temp.err('same key with different payload rejected', format($f$select public.place_order(pg_temp.po(%L, 'key-cod-0001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(%L, 1000, 1)), 50, 0, 10)), null, 'OTHER'))$f$, :'c1', :'bike'), 'idempotency_key_reuse');
select pg_temp.err('missing idempotency key rejected', format($f$select public.place_order(pg_temp.po(%L, '', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(%L, 1000, 1))))))$f$, :'c1', :'bike'), 'idempotency_key_required');

-- validation + atomic rollback
select pg_temp.err('insufficient stock', format($f$select public.place_order(pg_temp.po(%L, 'key-over-0001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(%L, 1000, 4))))))$f$, :'c1', :'bike'), 'insufficient_stock');
select pg_temp.err('multi-line order rolls back everything when 2nd line fails', format($f$select public.place_order(pg_temp.po(%L, 'key-roll-0001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(%L, 1000, 1))), pg_temp.vend((select vb from fx), jsonb_build_array(pg_temp.item(%L, 250.50, 9))))))$f$, :'c1', :'bike', :'pads'), 'insufficient_stock');
select pg_temp.ck('...first line stock untouched after rollback', pg_temp.stock(:'bike') = 3 and pg_temp.stock(:'pads') = 3 and (select count(*) = 1 from public.orders));
select pg_temp.err('price changed since cart', format($f$select public.place_order(pg_temp.po(%L, 'key-price-001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(%L, 999, 1))))))$f$, :'c1', :'bike'), 'price_changed');
select pg_temp.err('unapproved product', format($f$select public.place_order(pg_temp.po(%L, 'key-unapp-001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item('10000000-0000-0000-0000-000000000003', 10, 1))))))$f$, :'c1'), 'product_unavailable');
select pg_temp.err('product of another vendor claimed', format($f$select public.place_order(pg_temp.po(%L, 'key-vend-0001', 'cod', jsonb_build_array(pg_temp.vend((select vb from fx), jsonb_build_array(pg_temp.item(%L, 1000, 1))))))$f$, :'c1', :'bike'), 'invalid_vendor');
select pg_temp.err('forged subtotal', format($f$select public.place_order(jsonb_set(pg_temp.po(%L, 'key-forge-001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(%L, 1000, 1))))), '{subtotal}', '1'))$f$, :'c1', :'bike'), 'totals_mismatch');
select pg_temp.err('duplicate product in payload', format($f$select public.place_order(pg_temp.po(%L, 'key-dup-00001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(%L, 1000, 1), pg_temp.item(%L, 1000, 1))))))$f$, :'c1', :'bike', :'bike'), 'duplicate_product');
select pg_temp.ck('failed validations changed nothing', pg_temp.stock(:'bike') = 3 and (select count(*) = 1 from public.orders));
update public.vendor_profiles set verification_status='suspended' where business_name='Beta';
select pg_temp.err('suspended vendor cannot fulfil', format($f$select public.place_order(pg_temp.po(%L, 'key-susp-0001', 'cod', jsonb_build_array(pg_temp.vend((select vb from fx), jsonb_build_array(pg_temp.item(%L, 250.50, 1))))))$f$, :'c1', :'pads'), 'vendor_unavailable');
update public.vendor_profiles set verification_status='approved' where business_name='Beta';

-- coupon
select public.place_order(pg_temp.po(:'c2', 'key-coupon-001', 'cod', jsonb_build_array(pg_temp.vend((select vb from fx), jsonb_build_array(pg_temp.item(:'pads', 250.50, 1)), 0, 100)), '20000000-0000-0000-0000-000000000001'));
select pg_temp.ck('coupon used_count incremented', (select used_count = 1 from public.coupons));
select pg_temp.err('coupon usage limit enforced', format($f$select public.place_order(pg_temp.po(%L, 'key-coupon-002', 'cod', jsonb_build_array(pg_temp.vend((select vb from fx), jsonb_build_array(pg_temp.item(%L, 250.50, 1)), 0, 100)), '20000000-0000-0000-0000-000000000001'))$f$, :'c1', :'pads'), 'coupon_unavailable');
select pg_temp.ck('coupon failure rolled back stock', pg_temp.stock(:'pads') = 2);
select pg_temp.ck('zero-total order refused', (select pg_temp.err('x', format($f$select public.place_order(pg_temp.po(%L, 'key-zero-0001', 'cod', jsonb_build_array(pg_temp.vend((select vb from fx), jsonb_build_array(pg_temp.item(%L, 250.50, 1)), 0, 250.50))))$f$, :'c1', :'pads'), 'invalid_total')) like 'PASS%');

-- ================= vendor fulfilment (COD order of c1 / vendor A) =================
create temp table o1 as select o.id order_id, vo.id vo_id, p.id pay_id from public.orders o join public.vendor_orders vo on vo.order_id = o.id join public.payments p on p.order_id = o.id where o.customer_id = :'c1';
select pg_temp.err('wrong vendor cannot touch the order', format($f$select public.transition_vendor_order(%L, %L, 'accepted', null, 'vendor', null)$f$, (select vo_id from o1), (select vb from fx)), 'not_found');
select pg_temp.err('cannot skip states (pending -> preparing)', format($f$select public.transition_vendor_order(%L, %L, 'preparing', null, 'vendor', null)$f$, (select vo_id from o1), (select va from fx)), 'invalid_transition');
select public.transition_vendor_order((select vo_id from o1), (select va from fx), 'accepted', '00000000-0000-0000-0000-0000000000a1', 'vendor', 'ok');
select pg_temp.ck('accept stamps accepted_at and logs history with note+actor', (select accepted_at is not null from public.vendor_orders where id = (select vo_id from o1)) and (select count(*) = 1 from public.order_status_history where to_status = 'accepted' and changed_by = '00000000-0000-0000-0000-0000000000a1' and note = 'ok'));
select pg_temp.err('vendor cannot reject after accepting', format($f$select public.transition_vendor_order(%L, %L, 'rejected', null, 'vendor', 'x')$f$, (select vo_id from o1), (select va from fx)), 'invalid_transition');
select pg_temp.err('customer cannot cancel someone else''s order', format($f$select public.cancel_order(%L, %L, 'customer', 'x')$f$, (select order_id from o1), :'c2'), 'not_found');
select public.transition_vendor_order((select vo_id from o1), (select va from fx), 'preparing', null, 'vendor', null);
select pg_temp.err('customer cannot cancel once preparation started', format($f$select public.cancel_order(%L, %L, 'customer', 'changed mind')$f$, (select order_id from o1), :'c1'), 'preparation_started');
select pg_temp.err('COD cannot be collected before dispatch', format($f$select public.record_cod_collection(%L, %L)$f$, (select pay_id from o1), :'ad'), 'not_dispatched');
select public.transition_vendor_order((select vo_id from o1), (select va from fx), 'ready_for_dispatch', null, 'vendor', null);
select public.transition_vendor_order((select vo_id from o1), (select va from fx), 'out_for_delivery', null, 'vendor', null);
select public.transition_vendor_order((select vo_id from o1), (select va from fx), 'delivered', null, 'vendor', null);
select pg_temp.ck('delivered -> parent order completed', (select status = 'completed' from public.orders where id = (select order_id from o1)));
select pg_temp.ck('settlement created: gross 2000 - commission 200 = net 1800, pending (COD not collected)', (select gross_amount = 2000 and commission_amount = 200 and net_amount = 1800 and status = 'pending' from public.vendor_settlements));
select pg_temp.err('terminal vendor order cannot be cancelled', format($f$select public.transition_vendor_order(%L, null, 'cancelled', null, 'admin', 'x')$f$, (select vo_id from o1)), 'invalid_transition');
select public.record_cod_collection((select pay_id from o1), :'ad');
select pg_temp.ck('COD collected: payment+order successful, settlement ready, audit written', (select status = 'successful' and recorded_by = :'ad' and paid_at is not null from public.payments where id = (select pay_id from o1)) and (select payment_status = 'successful' from public.orders where id = (select order_id from o1)) and (select status = 'ready' from public.vendor_settlements) and (select count(*) = 1 from public.audit_log where action = 'cod_collected'));
select pg_temp.err('COD cannot be collected twice', format($f$select public.record_cod_collection(%L, %L)$f$, (select pay_id from o1), :'ad'), 'not_collectable');
select pg_temp.ck('delivery does not touch stock again', pg_temp.stock(:'bike') = 3);

-- ================= online payment lifecycle =================
select public.place_order(pg_temp.po(:'c1', 'key-onl-00001', 'online', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(:'bike', 1000, 1)), 0, 0, 10))));
create temp table o2 as select o.id order_id, vo.id vo_id, p.id pay_id from public.orders o join public.vendor_orders vo on vo.order_id = o.id join public.payments p on p.order_id = o.id where o.idempotency_key = 'key-onl-00001';
select pg_temp.ck('online order pending, not released to vendor, payment due set', (select o.status = 'pending' and vo.released_at is null and o.payment_due_at is not null and p.provider = 'testpay' and p.status = 'pending' from public.orders o join public.vendor_orders vo on vo.order_id = o.id join public.payments p on p.order_id = o.id where o.id = (select order_id from o2)));
select pg_temp.err('vendor cannot act on unpaid order', format($f$select public.transition_vendor_order(%L, %L, 'accepted', null, 'vendor', null)$f$, (select vo_id from o2), (select va from fx)), 'order_not_active');
select public.attach_provider_order((select pay_id from o2), 'testpay', 'po_1');
select pg_temp.ck('provider order attached -> processing', (select status = 'processing' and provider_order_id = 'po_1' from public.payments where id = (select pay_id from o2)) and (select payment_status = 'processing' from public.orders where id = (select order_id from o2)));
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"e0","event_type":"payment.succeeded","provider_order_id":"nope","amount":1000,"currency":"INR"}'), false);
select pg_temp.ck('unmatched provider order is recorded and ignored', current_setting('t.o') = 'unmatched');
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"e1","event_type":"payment.succeeded","provider_order_id":"po_1","provider_payment_id":"pay_1","amount":1,"currency":"INR"}'), false);
select pg_temp.ck('amount mismatch is flagged, NOT marked paid', current_setting('t.o') = 'amount_mismatch'
   and (select status = 'processing' and needs_review from public.payments where id = (select pay_id from o2)) and (select status = 'pending' from public.orders where id = (select order_id from o2)));
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"e1b","event_type":"payment.succeeded","provider_order_id":"po_1","amount":1000,"currency":"USD"}'), false);
select pg_temp.ck('currency mismatch also flagged', current_setting('t.o') = 'amount_mismatch');
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"e2","event_type":"payment.succeeded","provider_order_id":"po_1","provider_payment_id":"pay_1","amount":1000,"currency":"INR"}'), false);
select pg_temp.ck('verified success confirms order and releases vendor order', current_setting('t.o') = 'applied'
   and (select status = 'confirmed' and payment_status = 'successful' from public.orders where id = (select order_id from o2)) and (select released_at is not null from public.vendor_orders where id = (select vo_id from o2))
   and (select status = 'successful' and paid_at is not null and provider_payment_id = 'pay_1' from public.payments where id = (select pay_id from o2)));
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"e2","event_type":"payment.succeeded","provider_order_id":"po_1","amount":1000,"currency":"INR"}'), false);
select pg_temp.ck('duplicate webhook is a no-op', current_setting('t.o') = 'duplicate' and (select count(*) = 1 from public.payment_events where event_id = 'e2'));
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"e3","event_type":"payment.succeeded","provider_order_id":"po_1","amount":1000,"currency":"INR"}'), false);
select pg_temp.ck('same payment re-sent under a new event id is already_applied', current_setting('t.o') = 'already_applied' and (select count(*) = 1 from public.payments where order_id = (select order_id from o2)));
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"e4","event_type":"payment.failed","provider_order_id":"po_1","amount":1000,"currency":"INR"}'), false);
select pg_temp.ck('late "failed" event cannot downgrade a successful payment', current_setting('t.o') = 'ignored' and (select status = 'successful' from public.payments where id = (select pay_id from o2)));
select pg_temp.ck('vendor notified only after payment', (select count(*) = 1 from public.notifications where user_id = '00000000-0000-0000-0000-0000000000a1' and related_id = (select vo_id from o2)));

-- paid online order rejected by the vendor -> stock back once, refund REQUESTED (not processed)
select pg_temp.ck('stock before reject (3-1=2)', pg_temp.stock(:'bike') = 2);
select public.transition_vendor_order((select vo_id from o2), (select va from fx), 'rejected', null, 'vendor', 'Out of stock at shop');
select pg_temp.ck('reject restores stock exactly once', pg_temp.stock(:'bike') = 3 and (select count(*) = 1 and bool_and(stock_restored_at is not null) from public.order_items where vendor_order_id = (select vo_id from o2)));
select pg_temp.ck('reject -> parent cancelled with reason, refund requested for full amount, payment NOT claimed refunded', (select status = 'cancelled' from public.orders where id = (select order_id from o2))
   and (select status = 'requested' and amount = 1000 and vendor_order_id = (select vo_id from o2) from public.refunds where payment_id = (select pay_id from o2)) and (select status = 'successful' and refunded_amount = 0 from public.payments where id = (select pay_id from o2)));
select pg_temp.err('rejected order cannot be cancelled again', format($f$select public.cancel_order(%L, %L, 'customer', 'x')$f$, (select order_id from o2), :'c1'), 'not_cancellable');
select public.cm_restore_stock((select vo_id from o2));
select pg_temp.ck('no second stock restore possible', pg_temp.stock(:'bike') = 3);

-- refund lifecycle
create temp table r2 as select id from public.refunds limit 1;
select pg_temp.err('cannot jump requested -> processed', format($f$select public.apply_refund_result(%L, 'processed', %L, 'rf_1', null, null)$f$, (select id from r2), :'ad'), 'invalid_transition');
select public.apply_refund_result((select id from r2), 'approved', :'ad', null, null, 'approved by finance');
select public.apply_refund_result((select id from r2), 'processed', :'ad', 'rf_1', null, null);
select pg_temp.ck('processed refund -> payment refunded, order payment_status refunded', (select status = 'refunded' and refunded_amount = 1000 from public.payments where id = (select pay_id from o2)) and (select payment_status = 'refunded' from public.orders where id = (select order_id from o2)));
select pg_temp.err('refund beyond paid amount refused', format($f$select public.cm_create_refund(%L, 1, 'x', %L, null, 'extra-1', null)$f$, (select pay_id from o2), :'ad'), 'payment_not_refundable');
select pg_temp.err('processed refund is terminal', format($f$select public.apply_refund_result(%L, 'failed', %L, null, 'x', null)$f$, (select id from r2), :'ad'), 'invalid_transition');

-- failed payment keeps reservation until deadline; retry; expiry restores stock once
select public.place_order(pg_temp.po(:'c2', 'key-onl-00002', 'online', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(:'bike', 1000, 2))))));
create temp table o3 as select o.id order_id, p.id pay_id from public.orders o join public.payments p on p.order_id = o.id where o.idempotency_key = 'key-onl-00002';
select public.attach_provider_order((select pay_id from o3), 'testpay', 'po_3');
select public.apply_payment_event('{"provider":"testpay","event_id":"f1","event_type":"payment.failed","provider_order_id":"po_3","failure_reason":"card declined","amount":2000,"currency":"INR"}');
select pg_temp.ck('failed payment: payment failed, order still pending, stock still reserved', (select status = 'failed' and failure_reason = 'card declined' from public.payments where id = (select pay_id from o3)) and (select status = 'pending' and payment_status = 'failed' from public.orders where id = (select order_id from o3)) and pg_temp.stock(:'bike') = 1);
create temp table a3 as select public.new_payment_attempt((select order_id from o3), :'c2', 'testpay') id;
select pg_temp.ck('retry creates a new pending attempt', (select count(*) = 2 from public.payments where order_id = (select order_id from o3)) and (select status = 'pending' from public.payments where id = (select id from a3)));
select pg_temp.ck('second retry call returns the same open attempt', public.new_payment_attempt((select order_id from o3), :'c2', 'testpay') = (select id from a3));
select pg_temp.err('another customer cannot retry my payment', format($f$select public.new_payment_attempt(%L, %L, 'testpay')$f$, (select order_id from o3), :'c1'), 'not_found');
select public.attach_provider_order((select id from a3), 'testpay', 'po_3b');
update public.orders set payment_due_at = now() - interval '1 minute' where id = (select order_id from o3);
select set_config('t.n', public.expire_unpaid_orders(10)::text, false);
select pg_temp.ck('expiry cancels the unpaid order', current_setting('t.n') = '1' and (select status = 'cancelled' and cancelled_by_role = 'system' from public.orders where id = (select order_id from o3)));
select pg_temp.ck('expiry returned the stock once; payments closed; no refund (nothing was paid)', pg_temp.stock(:'bike') = 3 and (select bool_and(status in ('failed','cancelled')) from public.payments where order_id = (select order_id from o3)) and (select count(*) = 0 from public.refunds where order_id = (select order_id from o3)));
select set_config('t.n', public.expire_unpaid_orders(10)::text, false);
select pg_temp.ck('running expiry again does nothing', current_setting('t.n') = '0' and pg_temp.stock(:'bike') = 3);
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"f2","event_type":"payment.succeeded","provider_order_id":"po_3b","provider_payment_id":"pay_3","amount":2000,"currency":"INR"}'), false);
select pg_temp.ck('LATE success after cancellation -> flagged + refund requested, order stays cancelled', current_setting('t.o') = 'applied_late_refund_requested'
   and (select status = 'cancelled' from public.orders where id = (select order_id from o3)) and (select needs_review from public.payments where id = (select id from a3)) and (select status = 'requested' and amount = 2000 from public.refunds where order_id = (select order_id from o3)) and pg_temp.stock(:'bike') = 3);

-- customer cancellation of a paid, not yet prepared order
select public.place_order(pg_temp.po(:'c1', 'key-onl-00003', 'online', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(:'bike', 1000, 1))))));
create temp table o4 as select o.id order_id, vo.id vo_id, p.id pay_id from public.orders o join public.vendor_orders vo on vo.order_id = o.id join public.payments p on p.order_id = o.id where o.idempotency_key = 'key-onl-00003';
select public.attach_provider_order((select pay_id from o4), 'testpay', 'po_4');
select public.apply_payment_event('{"provider":"testpay","event_id":"g1","event_type":"payment.succeeded","provider_order_id":"po_4","amount":1000,"currency":"INR"}');
select public.transition_vendor_order((select vo_id from o4), (select va from fx), 'accepted', null, 'vendor', null);
select public.cancel_order((select order_id from o4), :'c1', 'customer', 'Changed my mind');
select pg_temp.ck('customer cancel of accepted order: cancelled, stock back, refund requested, reason stored', (select status = 'cancelled' and cancelled_reason = 'Changed my mind' and cancelled_by_role = 'customer' from public.orders where id = (select order_id from o4))
   and pg_temp.stock(:'bike') = 3 and (select status = 'requested' and amount = 1000 from public.refunds where order_id = (select order_id from o4)));
select pg_temp.ck('cancellation history recorded with actor', (select count(*) >= 1 from public.order_status_history where order_id = (select order_id from o4) and to_status = 'cancelled' and changed_by = :'c1'));

-- partial refunds + duplicate prevention (admin refund on a paid order)
select public.place_order(pg_temp.po(:'c1', 'key-onl-00004', 'online', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(:'bike', 1000, 2)), 0, 0, 10))));
create temp table o5 as select o.id order_id, vo.id vo_id, p.id pay_id from public.orders o join public.vendor_orders vo on vo.order_id = o.id join public.payments p on p.order_id = o.id where o.idempotency_key = 'key-onl-00004';
select public.attach_provider_order((select pay_id from o5), 'testpay', 'po_5');
select public.apply_payment_event('{"provider":"testpay","event_id":"h1","event_type":"payment.succeeded","provider_order_id":"po_5","amount":2000,"currency":"INR"}');
select public.cm_create_refund((select pay_id from o5), 600, 'Damaged item', :'ad', (select vo_id from o5), 'adm-1', null);
select pg_temp.ck('same refund idempotency key returns the same refund', public.cm_create_refund((select pay_id from o5), 600, 'Damaged item', :'ad', (select vo_id from o5), 'adm-1', null) = (select id from public.refunds where idempotency_key = 'adm-1') and (select count(*) = 1 from public.refunds where payment_id = (select pay_id from o5)));
select pg_temp.err('refunds cannot exceed paid amount (600 + 1500 > 2000)', format($f$select public.cm_create_refund(%L, 1500, 'x', %L, null, 'adm-2', null)$f$, (select pay_id from o5), :'ad'), 'refund_exceeds');
select pg_temp.ck('a refund up to the remaining amount is allowed', public.cm_create_refund((select pay_id from o5), 1400, 'rest', :'ad', null, 'adm-3', null) is not null);
update public.refunds set status = 'rejected' where idempotency_key = 'adm-3';
select public.apply_refund_result((select id from public.refunds where idempotency_key = 'adm-1'), 'approved', :'ad', null, null, null);
select public.apply_refund_result((select id from public.refunds where idempotency_key = 'adm-1'), 'failed', :'ad', null, 'bank error', null);
select pg_temp.ck('failed refund can be re-approved then processed', (select status = 'failed' and failure_reason = 'bank error' from public.refunds where idempotency_key = 'adm-1') and public.apply_refund_result((select id from public.refunds where idempotency_key = 'adm-1'), 'approved', :'ad', null, null, null) ->> 'status' = 'approved');
-- deliver it, then process the refund: settlement deductions applied
select public.transition_vendor_order((select vo_id from o5), (select va from fx), 'accepted', null, 'vendor', null);
select public.transition_vendor_order((select vo_id from o5), (select va from fx), 'preparing', null, 'vendor', null);
select public.transition_vendor_order((select vo_id from o5), (select va from fx), 'ready_for_dispatch', null, 'vendor', null);
select public.transition_vendor_order((select vo_id from o5), (select va from fx), 'delivered', null, 'vendor', null);
select pg_temp.ck('online-paid delivered order -> settlement is ready immediately (net 1800)', (select status = 'ready' and net_amount = 1800 and gross_amount = 2000 and commission_amount = 200 from public.vendor_settlements where vendor_order_id = (select vo_id from o5)));
select public.apply_refund_result((select id from public.refunds where idempotency_key = 'adm-1'), 'processed', :'ad', 'rf_5', null, null);
select pg_temp.ck('partial refund processed -> payment partially_refunded; settlement deduction 600, net 1200', (select status = 'partially_refunded' and refunded_amount = 600 from public.payments where id = (select pay_id from o5)) and (select payment_status = 'partially_refunded' from public.orders where id = (select order_id from o5))
   and (select deductions_amount = 600 and net_amount = 1200 from public.vendor_settlements where vendor_order_id = (select vo_id from o5)));

-- refund confirmation via provider webhook (idempotent)
select public.cm_create_refund((select pay_id from o5), 700, 'Return accepted', :'ad', null, 'adm-webhook', null);
select public.apply_refund_result((select id from public.refunds where idempotency_key = 'adm-webhook'), 'approved', :'ad', 'rf_wh', null, null);
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"rfe1","event_type":"refund.processed","provider_refund_id":"rf_wh"}'), false);
select pg_temp.ck('refund.processed webhook completes an approved refund', current_setting('t.o') = 'applied' and (select status = 'processed' from public.refunds where idempotency_key = 'adm-webhook')
   and (select refunded_amount = 1300 and status = 'partially_refunded' from public.payments where id = (select pay_id from o5)));
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"rfe1","event_type":"refund.processed","provider_refund_id":"rf_wh"}'), false);
select pg_temp.ck('duplicate refund webhook ignored (no double refund)', current_setting('t.o') = 'duplicate' and (select refunded_amount = 1300 from public.payments where id = (select pay_id from o5)));
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"rfe2","event_type":"refund.processed","provider_refund_id":"rf_wh"}'), false);
select pg_temp.ck('same refund re-notified under a new event id is not applied twice', current_setting('t.o') = 'ignored' and (select refunded_amount = 1300 from public.payments where id = (select pay_id from o5)));
select set_config('t.o', pg_temp.ev('{"provider":"testpay","event_id":"rfe3","event_type":"refund.processed","provider_refund_id":"unknown"}'), false);
select pg_temp.ck('refund webhook for unknown refund is recorded as unmatched', current_setting('t.o') = 'unmatched');
select pg_temp.ck('customer notified of processed refund', (select count(*) >= 2 from public.notifications where title = 'Refund processed'));

-- ================= multi-vendor order =================
select public.place_order(pg_temp.po(:'c1', 'key-mv-000001', 'cod', jsonb_build_array(pg_temp.vend((select va from fx), jsonb_build_array(pg_temp.item(:'bike', 1000, 1)), 20, 10), pg_temp.vend((select vb from fx), jsonb_build_array(pg_temp.item(:'pads', 250.50, 1)), 30, 5))));
create temp table o6 as select o.id order_id from public.orders o where o.idempotency_key = 'key-mv-000001';
select pg_temp.ck('one order -> two vendor orders -> two items; amounts add up', (select count(*) = 2 from public.vendor_orders where order_id = (select order_id from o6)) and (select total_amount = 1000 + 250.50 + 50 - 15 from public.orders where id = (select order_id from o6)));
select public.transition_vendor_order((select id from public.vendor_orders where order_id = (select order_id from o6) and vendor_id = (select vb from fx)), (select vb from fx), 'rejected', null, 'vendor', 'cannot supply');
select pg_temp.ck('one vendor rejecting leaves the other vendor''s part and the parent active', (select status = 'confirmed' from public.orders where id = (select order_id from o6)) and (select status = 'pending' from public.vendor_orders where order_id = (select order_id from o6) and vendor_id = (select va from fx)));
select pg_temp.ck('COD amount due reduced by the rejected vendor part', (select amount = 1000 + 250.50 + 50 - 15 - (250.50 + 30 - 5) from public.payments where order_id = (select order_id from o6)));
select pg_temp.ck('rejected vendor part stock restored', pg_temp.stock(:'pads') = 2);
select public.cancel_order((select order_id from o6), :'c1', 'customer', 'no longer needed');
select pg_temp.ck('customer cancel finishes the rest -> parent cancelled, stock back (5 - 2 delivered COD - 2 delivered online = 1)', (select status = 'cancelled' from public.orders where id = (select order_id from o6)) and pg_temp.stock(:'bike') = 1 and (select status = 'cancelled' from public.payments where order_id = (select order_id from o6)));

-- ================= permissions / RLS =================
set role authenticated;
select pg_temp.err('API roles cannot call place_order', 'select public.place_order(''{}''::jsonb)', 'permission denied');
select pg_temp.err('API roles cannot call apply_payment_event', 'select public.apply_payment_event(''{}''::jsonb)', 'permission denied');
select pg_temp.err('API roles cannot call cancel_order', 'select public.cancel_order(gen_random_uuid(), null, ''admin'', ''x'')', 'permission denied');
select pg_temp.err('API roles cannot call transition_vendor_order', 'select public.transition_vendor_order(gen_random_uuid(), null, ''accepted'', null, ''admin'', null)', 'permission denied');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
set role authenticated;
update public.vendor_orders set status = 'rejected';
reset role;
select pg_temp.ck('vendor can no longer change a vendor order straight through the API (policy dropped)', (select count(*) = 0 from public.vendor_orders where status = 'rejected' and rejection_reason is null and vendor_id = (select va from fx)));
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false);
set role authenticated;
select pg_temp.ck('customer 2 cannot see customer 1 payments/events/settlements/audit', (select count(*) from public.payments where customer_id = '00000000-0000-0000-0000-0000000000c1') = 0 and (select count(*) from public.payment_events) = 0 and (select count(*) from public.vendor_settlements) = 0 and (select count(*) from public.audit_log) = 0);
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', false);
set role authenticated;
select pg_temp.ck('vendor B sees only its own settlements', (select count(*) from public.vendor_settlements) = 0);
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
set role authenticated;
select pg_temp.ck('vendor A sees its settlements', (select count(*) >= 2 from public.vendor_settlements));
reset role;

-- ================= global invariants =================
select pg_temp.ck('INVARIANT no product has negative stock', (select count(*) = 0 from public.products where stock_quantity < 0));
select pg_temp.ck('INVARIANT stock = initial - units in non-restored order items', (select bool_and(p.stock_quantity = case p.id when :'bike' then 5 when :'pads' then 3 end - coalesce(x.q, 0)) from public.products p left join (select product_id, sum(quantity) q from public.order_items where stock_restored_at is null group by product_id) x on x.product_id = p.id where p.id in (:'bike', :'pads')));
select pg_temp.ck('INVARIANT order totals = sum of vendor order totals', (select count(*) = 0 from public.orders o where total_amount <> (select sum(total_amount) from public.vendor_orders where order_id = o.id)));
select pg_temp.ck('INVARIANT never two open payment attempts per order', (select count(*) = 0 from (select order_id from public.payments where status in ('pending','processing') group by order_id having count(*) > 1) x));
select pg_temp.ck('INVARIANT refunds never exceed payment amount', (select count(*) = 0 from public.payments p where (select coalesce(sum(amount),0) from public.refunds where payment_id = p.id and status in ('requested','approved','processed')) > p.amount));
