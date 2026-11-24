-- Behavioural tests of the Step 6 SQL functions. Prints PASS/FAIL lines.
\set ON_ERROR_STOP off
\pset tuples_only on
\pset format unaligned
create or replace function pg_temp.ck(label text, cond boolean) returns text language sql as $$ select case when coalesce(cond,false) then 'PASS ' else 'FAIL ' end || label $$;
create or replace function pg_temp.err(label text, stmt text, code text) returns text language plpgsql as $$
begin execute stmt; return 'FAIL ' || label || ' (no error)';
exception when others then return case when sqlerrm like '%' || code || '%' then 'PASS ' else 'FAIL ' end || label || case when sqlerrm like '%'||code||'%' then '' else ' (got: ' || sqlerrm || ')' end; end $$;

insert into auth.users (id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000a1','va@x.t','{"role":"vendor"}'),('00000000-0000-0000-0000-0000000000a2','vb@x.t','{"role":"vendor"}'),
 ('00000000-0000-0000-0000-0000000000c1','c1@x.t','{}'),('00000000-0000-0000-0000-0000000000c2','c2@x.t','{}'),('00000000-0000-0000-0000-0000000000ad','ad@x.t','{}');
update public.profiles set role='admin' where id='00000000-0000-0000-0000-0000000000ad';
insert into public.vendor_profiles (user_id,business_name,business_types,address_line1,city,state,postal_code,contact_phone,verification_status,pickup_available) values
 ('00000000-0000-0000-0000-0000000000a1','Alpha','{service_provider}','a','Pune','MH','411001','+919800000001','approved',true),
 ('00000000-0000-0000-0000-0000000000a2','Beta','{service_provider}','a','Pune','MH','411001','+919800000002','approved',false);
create table public.zz_fx as select (select id from public.vendor_profiles where business_name='Alpha') va, (select id from public.vendor_profiles where business_name='Beta') vb,
  (select id from public.service_categories where slug='general-servicing') cat;
insert into public.vendor_services (id,vendor_id,service_category_id,name,price,estimated_duration_minutes,max_bookings_per_slot) select '30000000-0000-0000-0000-000000000001',va,cat,'Full service',499.00,120,1 from public.zz_fx;
insert into public.vendor_services (id,vendor_id,service_category_id,name,price) select '30000000-0000-0000-0000-000000000002',vb,cat,'Basic (Beta)',300 from public.zz_fx;
grant select on public.zz_fx to authenticated, anon;
\set svc '30000000-0000-0000-0000-000000000001'
\set svcb '30000000-0000-0000-0000-000000000002'
\set c1 '00000000-0000-0000-0000-0000000000c1'
\set c2 '00000000-0000-0000-0000-0000000000c2'
\set ad '00000000-0000-0000-0000-0000000000ad'
\set va '00000000-0000-0000-0000-0000000000a1'
create or replace function pg_temp.pl(p_cust uuid, p_svc uuid, p_day date, p_start text, p_pickup boolean default false) returns jsonb language sql as $$
 select jsonb_build_object('customer_id',p_cust,'service_id',p_svc,'cycle_brand','Hero','issue_description','Brakes squeal and chain skips','preferred_date',p_day,'slot_start',p_start,'slot_end',(p_start::time + interval '1 hour')::text,
   'needs_pickup_dropoff',p_pickup,'pickup_address',jsonb_build_object('city','Pune'),'dropoff_address',jsonb_build_object('city','Pune'),'pickup_charge',30,'dropoff_charge',20,'customer_instructions','Call at gate') $$;
create or replace function pg_temp.bk(n int) returns uuid language sql as $$ select id from (select id, row_number() over (order by created_at, id) rn from public.service_bookings) x where rn = n $$;

-- ===== create =====
select set_config('t.r', public.create_service_booking(pg_temp.pl(:'c1', :'svc', current_date + 3, '10:00', true))::text, false);
select pg_temp.ck('booking created pending with price read from the DATABASE (499)', (select status='pending' and estimated_price=499 and service_name='Full service' and vendor_name='Alpha' and final_price is null and confirmed_date is null from public.service_bookings));
select pg_temp.ck('pickup request created with charge snapshots + instructions', (select pickup_status='pending' and delivery_status='pending' and pickup_charge=30 and dropoff_charge=20 and customer_instructions='Call at gate' from public.pickup_dropoff_requests));
select pg_temp.ck('creation notifies customer, vendor and admin exactly once each', (select count(*) filter (where user_id=:'c1')=1 and count(*) filter (where user_id=:'va')=1 and count(*) filter (where user_id=:'ad')=1 from public.notifications));
select pg_temp.ck('initial status history row written with the customer as actor', (select count(*)=1 and bool_and(changed_by=:'c1' and to_status='pending') from public.booking_status_history));
select pg_temp.err('same customer, same service, same slot = duplicate', format($f$select public.create_service_booking(pg_temp.pl(%L, %L, current_date + 3, '10:00', true))$f$, :'c1', :'svc'), 'duplicate_booking');
select pg_temp.ck('a different slot is fine', public.create_service_booking(pg_temp.pl(:'c1', :'svc', current_date + 3, '14:00')) is not null);
select pg_temp.err('unknown service', format($f$select public.create_service_booking(pg_temp.pl(%L, gen_random_uuid(), current_date + 3, '10:00'))$f$, :'c1'), 'service_unavailable');
select pg_temp.err('pickup refused when vendor does not offer it', format($f$select public.create_service_booking(pg_temp.pl(%L, %L, current_date + 3, '10:00', true))$f$, :'c1', :'svcb'), 'pickup_not_offered');
update public.vendor_services set is_available = false where id = :'svc';
select pg_temp.err('service switched off', format($f$select public.create_service_booking(pg_temp.pl(%L, %L, current_date + 5, '10:00'))$f$, :'c2', :'svc'), 'service_unavailable');
update public.vendor_services set is_available = true, is_active = false where id = :'svc';
select pg_temp.err('service deactivated', format($f$select public.create_service_booking(pg_temp.pl(%L, %L, current_date + 5, '10:00'))$f$, :'c2', :'svc'), 'service_unavailable');
update public.vendor_services set is_active = true where id = :'svc';
update public.vendor_profiles set verification_status = 'suspended' where business_name = 'Alpha';
select pg_temp.err('suspended vendor cannot receive bookings', format($f$select public.create_service_booking(pg_temp.pl(%L, %L, current_date + 5, '10:00'))$f$, :'c2', :'svc'), 'vendor_unavailable');
update public.vendor_profiles set verification_status = 'approved' where business_name = 'Alpha';
update public.service_categories set is_active = false where slug = 'general-servicing';
select pg_temp.err('inactive category blocks new bookings', format($f$select public.create_service_booking(pg_temp.pl(%L, %L, current_date + 5, '10:00'))$f$, :'c2', :'svc'), 'service_unavailable');
update public.service_categories set is_active = true where slug = 'general-servicing';
select pg_temp.err('admin / vendor accounts cannot book as customers', format($f$select public.create_service_booking(pg_temp.pl(%L, %L, current_date + 5, '10:00'))$f$, :'ad', :'svc'), 'account_inactive');

-- ===== accept + capacity =====
select pg_temp.err('wrong vendor cannot accept', format($f$select public.accept_service_booking(pg_temp.bk(1), (select vb from public.zz_fx), null, null, null, null, null)$f$), 'not_found');
select public.accept_service_booking(pg_temp.bk(1), (select va from public.zz_fx), :'va', null, null, null, 'see you then');
select pg_temp.ck('accept confirms the PREFERRED slot, keeps preferred and confirmed apart, stamps accepted_at', (select status='accepted' and confirmed_date=preferred_date and confirmed_slot_start=preferred_slot_start and accepted_at is not null from public.service_bookings where id=pg_temp.bk(1)));
select pg_temp.ck('accept logged with note+actor and notified the customer', (select count(*)=1 from public.booking_status_history where booking_id=pg_temp.bk(1) and to_status='accepted' and note='see you then' and changed_by=:'va') and (select count(*)=1 from public.notifications where user_id=:'c1' and event_key like '%:status:accepted'));
select pg_temp.err('cannot accept twice', format($f$select public.accept_service_booking(%L, (select va from public.zz_fx), %L, null,null,null,null)$f$, (select pg_temp.bk(1)), :'va'), 'invalid_transition');
select public.create_service_booking(pg_temp.pl(:'c2', :'svc', current_date + 3, '10:00'));
select pg_temp.err('capacity 1: a second ACCEPTED booking in the same confirmed slot is refused', format($f$select public.accept_service_booking(pg_temp.bk(3), (select va from public.zz_fx), %L, null,null,null,null)$f$, :'va'), 'slot_full');
select pg_temp.ck('...the refused booking is still pending (nothing half-applied)', (select status='pending' and confirmed_date is null from public.service_bookings where id=pg_temp.bk(3)));
select public.accept_service_booking(pg_temp.bk(3), (select va from public.zz_fx), :'va', current_date + 4, '10:00', '11:00', 'moved to next day');
select pg_temp.ck('vendor can confirm a DIFFERENT slot than preferred', (select confirmed_date = current_date + 4 and preferred_date = current_date + 3 from public.service_bookings where id=pg_temp.bk(3)));
select public.reschedule_service_booking(pg_temp.bk(3), (select va from public.zz_fx), :'va', 'vendor', current_date + 6, '09:00', '10:00', null);
select pg_temp.ck('reschedule changes only the confirmed slot and notifies', (select confirmed_date = current_date + 6 and preferred_date = current_date + 3 from public.service_bookings where id=pg_temp.bk(3)) and (select count(*) >= 1 from public.notifications where title='Appointment rescheduled'));
select pg_temp.err('cannot reschedule into a taken slot', format($f$select public.reschedule_service_booking(pg_temp.bk(3), (select va from public.zz_fx), %L, 'vendor', current_date + 3, '10:00', '11:00', null)$f$, :'va'), 'slot_full');

-- ===== status machine (pickup booking = bk1) =====
select pg_temp.err('cannot jump to in_service from accepted when pickup is required', format($f$select public.transition_service_booking(pg_temp.bk(1), (select va from public.zz_fx), 'in_service', %L, 'vendor', null)$f$, :'va'), 'invalid_transition');
select pg_temp.err('rejecting needs a reason', format($f$select public.transition_service_booking(pg_temp.bk(2), (select va from public.zz_fx), 'rejected', %L, 'vendor', '')$f$, :'va'), 'reason_required');
select pg_temp.err('another vendor cannot move my booking', format($f$select public.transition_service_booking(pg_temp.bk(1), (select vb from public.zz_fx), 'picked_up', null, 'vendor', null)$f$), 'not_found');
select pg_temp.err('customer 2 cannot cancel customer 1''s booking', format($f$select public.transition_service_booking(pg_temp.bk(1), null, 'cancelled', %L, 'customer', 'x y z')$f$, :'c2'), 'not_found');
select public.transition_service_booking(pg_temp.bk(1), (select va from public.zz_fx), 'picked_up', :'va', 'vendor', 'collected at gate');
select pg_temp.ck('picked_up records PICKUP completion on the logistics row (separate from booking status)', (select pickup_status='completed' and picked_up_at is not null and delivery_status='pending' from public.pickup_dropoff_requests));
select pg_temp.ck('customer notified of pickup (pickup_delivery type)', (select count(*)=1 from public.notifications where user_id=:'c1' and type='pickup_delivery' and event_key like '%:status:picked_up'));
select pg_temp.err('customer cannot cancel once the cycle was collected', format($f$select public.transition_service_booking(pg_temp.bk(1), null, 'cancelled', %L, 'customer', 'changed my mind')$f$, :'c1'), 'invalid_transition');
select pg_temp.err('vendor cannot cancel after pickup', format($f$select public.transition_service_booking(pg_temp.bk(1), (select va from public.zz_fx), 'cancelled', %L, 'vendor', 'oops')$f$, :'va'), 'invalid_transition');
select pg_temp.err('cannot complete before ready', format($f$select public.transition_service_booking(pg_temp.bk(1), (select va from public.zz_fx), 'completed', %L, 'vendor', null)$f$, :'va'), 'invalid_transition');

-- charges
select pg_temp.err('no charge on a booking that is not being worked on (pending)', format($f$select public.add_service_charge(pg_temp.bk(2), (select va from public.zz_fx), %L, 'vendor', 100, 'x')$f$, :'va'), 'charge_not_allowed');
select public.transition_service_booking(pg_temp.bk(1), (select va from public.zz_fx), 'in_service', :'va', 'vendor', null);
select public.add_service_charge(pg_temp.bk(1), (select va from public.zz_fx), :'va', 'vendor', 150, 'Replaced brake pads');
select pg_temp.ck('additional charge recorded; estimate untouched; final = estimate + charge', (select estimated_price=499 and final_price=649 and price_change_reason='Replaced brake pads' from public.service_bookings where id=pg_temp.bk(1)) and (select count(*)=1 and sum(amount)=150 from public.service_charges));
select public.add_service_charge(pg_temp.bk(1), (select va from public.zz_fx), :'va', 'vendor', -50, 'Goodwill discount');
select pg_temp.ck('adjustments are appended, history keeps both rows', (select final_price=599 and estimated_price=499 from public.service_bookings where id=pg_temp.bk(1)) and (select count(*)=2 from public.service_charges));
select pg_temp.err('zero charge refused', format($f$select public.add_service_charge(pg_temp.bk(1), (select va from public.zz_fx), %L, 'vendor', 0, 'x')$f$, :'va'), 'invalid_amount');
select pg_temp.err('reason required', format($f$select public.add_service_charge(pg_temp.bk(1), (select va from public.zz_fx), %L, 'vendor', 10, ' ')$f$, :'va'), 'reason_required');
select pg_temp.err('final price can never go negative', format($f$select public.add_service_charge(pg_temp.bk(1), (select va from public.zz_fx), %L, 'vendor', -5000, 'oops')$f$, :'va'), 'final_negative');
select pg_temp.err('other vendor cannot add charges', format($f$select public.add_service_charge(pg_temp.bk(1), (select vb from public.zz_fx), %L, 'vendor', 10, 'x')$f$, :'va'), 'not_found');
select pg_temp.ck('charge updates notify the customer', (select count(*)=2 from public.notifications where user_id=:'c1' and title='Repair charge updated'));
select public.add_service_note(pg_temp.bk(1), (select va from public.zz_fx), :'va', 'vendor', 'Chain also stretched; recommended replacement next visit');
select pg_temp.ck('service note stored with author', (select count(*)=1 and bool_and(author_id=:'va' and author_role='vendor') from public.service_booking_notes));
select public.transition_service_booking(pg_temp.bk(1), (select va from public.zz_fx), 'ready_for_delivery', :'va', 'vendor', null);

-- logistics coordination
create temp table pr as select id from public.pickup_dropoff_requests;
select pg_temp.err('delivery cannot be marked completed through coordination', format($f$select public.set_service_logistics(%L, (select va from public.zz_fx), %L, 'vendor', '{"delivery_status":"completed"}')$f$, (select id from pr), :'va'), 'use_booking_status');
select pg_temp.err('scheduled delivery needs a time', format($f$select public.set_service_logistics(%L, (select va from public.zz_fx), %L, 'vendor', '{"delivery_status":"scheduled"}')$f$, (select id from pr), :'va'), 'schedule_required');
select pg_temp.err('other vendor cannot coordinate', format($f$select public.set_service_logistics(%L, (select vb from public.zz_fx), null, 'vendor', '{"delivery_status":"cancelled"}')$f$, (select id from pr)), 'not_found');
select public.set_service_logistics((select id from pr), (select va from public.zz_fx), :'va', 'vendor', jsonb_build_object('delivery_status','scheduled','scheduled_delivery_at', now() + interval '2 days', 'notes', 'evening delivery'));
select pg_temp.ck('delivery scheduled; pickup completion untouched; notes stored', (select delivery_status='scheduled' and pickup_status='completed' and notes='evening delivery' from public.pickup_dropoff_requests) and (select count(*)>=1 from public.notifications where title='Return delivery scheduled'));
select public.set_service_logistics((select id from pr), (select va from public.zz_fx), :'va', 'vendor', '{"delivery_status":"failed"}');
select public.set_service_logistics((select id from pr), (select va from public.zz_fx), :'va', 'vendor', jsonb_build_object('delivery_status','scheduled','scheduled_delivery_at', now() + interval '3 days'));
select pg_temp.ck('failed attempt can be rescheduled', (select delivery_status='scheduled' from public.pickup_dropoff_requests));
select public.transition_service_booking(pg_temp.bk(1), (select va from public.zz_fx), 'completed', :'va', 'vendor', 'Cycle returned, customer happy');
select pg_temp.ck('completed records DELIVERY completion, completed_at and completion notes', (select status='completed' and completed_at is not null and completion_notes like 'Cycle returned%' from public.service_bookings where id=pg_temp.bk(1)) and (select delivery_status='completed' and delivered_at is not null from public.pickup_dropoff_requests));
select pg_temp.err('terminal booking cannot be coordinated any more', format($f$select public.set_service_logistics(%L, null, %L, 'admin', '{"pickup_status":"cancelled"}')$f$, (select id from pr), :'ad'), 'invalid_transition');
select pg_temp.ck('full status history for booking 1 (pending, accepted, picked_up, in_service, ready, completed)', (select count(*)=6 from public.booking_status_history where booking_id=pg_temp.bk(1)));

-- no-pickup flow + cancellation
select public.create_service_booking(pg_temp.pl(:'c2', :'svc', current_date + 8, '11:00'));
select public.accept_service_booking(pg_temp.bk(4), (select va from public.zz_fx), :'va', null, null, null, null);
select pg_temp.err('no-pickup booking cannot be marked picked_up', format($f$select public.transition_service_booking(pg_temp.bk(4), (select va from public.zz_fx), 'picked_up', %L, 'vendor', null)$f$, :'va'), 'invalid_transition');
select public.transition_service_booking(pg_temp.bk(4), (select va from public.zz_fx), 'in_service', :'va', 'vendor', 'customer dropped it off');
select pg_temp.ck('no-pickup booking goes accepted -> in_service directly', (select status='in_service' and not exists (select 1 from public.pickup_dropoff_requests where booking_id=pg_temp.bk(4)) from public.service_bookings where id=pg_temp.bk(4)));
select public.create_service_booking(pg_temp.pl(:'c2', :'svc', current_date + 9, '11:00', true));
select public.accept_service_booking(pg_temp.bk(5), (select va from public.zz_fx), :'va', null, null, null, null);
select public.transition_service_booking(pg_temp.bk(5), null, 'cancelled', :'c2', 'customer', 'Plans changed');
select pg_temp.ck('customer cancel: reason stored, slot released, logistics cancelled, vendor+admin notified', (select status='cancelled' and cancellation_reason='Plans changed' and cancelled_by=:'c2' and confirmed_date is null from public.service_bookings where id=pg_temp.bk(5))
   and (select pickup_status='cancelled' and delivery_status='cancelled' from public.pickup_dropoff_requests where booking_id=pg_temp.bk(5)) and (select count(*)=1 from public.notifications where user_id=:'va' and event_key='booking:'||pg_temp.bk(5)||':status:cancelled') and (select count(*)=1 from public.notifications where user_id=:'ad' and event_key='booking:'||pg_temp.bk(5)||':status:cancelled'));
select public.create_service_booking(pg_temp.pl(:'c2', :'svc', current_date + 9, '11:00', true));
select pg_temp.ck('after cancelling, the same slot can be booked again (duplicate guard only covers open bookings)', (select count(*)=1 from public.service_bookings where status='pending' and customer_id=:'c2' and preferred_date=current_date+9));
select public.transition_service_booking(pg_temp.bk(6), null, 'cancelled', :'ad', 'admin', 'Duplicate request');
select pg_temp.ck('admin can cancel a pending booking', (select status='cancelled' from public.service_bookings where id=pg_temp.bk(6)));
select pg_temp.err('admin can cancel mid-repair, customer cannot', format($f$select public.transition_service_booking(pg_temp.bk(4), null, 'cancelled', %L, 'customer', 'give it back')$f$, :'c2'), 'invalid_transition');
select public.transition_service_booking(pg_temp.bk(4), null, 'cancelled', :'ad', 'admin', 'Vendor closed');
select pg_temp.ck('admin cancel of an in-service booking works', (select status='cancelled' from public.service_bookings where id=pg_temp.bk(4)));
select pg_temp.err('accept function cannot be used through transition', format($f$select public.transition_service_booking(pg_temp.bk(2), (select va from public.zz_fx), 'accepted', %L, 'vendor', null)$f$, :'va'), 'use_accept');

-- notification dedupe
select public.cm_notify_once(:'c1', 'service_booking', 't', 'm', 'service_booking', pg_temp.bk(1), 'dedupe-test');
select public.cm_notify_once(:'c1', 'service_booking', 't', 'm', 'service_booking', pg_temp.bk(1), 'dedupe-test');
select pg_temp.ck('same event_key twice = one notification row', (select count(*)=1 from public.notifications where event_key='dedupe-test'));

-- ===== security =====
set role authenticated;
select pg_temp.err('API roles cannot call create_service_booking', 'select public.create_service_booking(''{}''::jsonb)', 'permission denied');
select pg_temp.err('API roles cannot call transition_service_booking', 'select public.transition_service_booking(gen_random_uuid(), null, ''cancelled'', null, ''admin'', ''x'')', 'permission denied');
select pg_temp.err('API roles cannot call add_service_charge', 'select public.add_service_charge(gen_random_uuid(), null, null, ''admin'', 5, ''x'')', 'permission denied');
reset role;
select set_config('request.jwt.claim.sub', :'va', false); set role authenticated;
update public.service_bookings set final_price = 1 where vendor_id = (select va from public.zz_fx);
update public.pickup_dropoff_requests set pickup_status = 'cancelled';
reset role;
select pg_temp.ck('vendor can no longer write bookings / pickup rows straight through the API (policies dropped)', (select count(*)=0 from public.service_bookings where final_price = 1) and (select count(*) = 0 from public.pickup_dropoff_requests where pickup_status='cancelled' and booking_id = pg_temp.bk(1)));
select set_config('request.jwt.claim.sub', :'c2', false); set role authenticated;
select pg_temp.ck('customer 2 cannot see customer 1''s charges / notes / bookings', (select count(*) from public.service_charges) = 0 and (select count(*) from public.service_booking_notes) = 0 and (select count(*) from public.service_bookings where customer_id = :'c1') = 0);
reset role;
select set_config('request.jwt.claim.sub', :'va', false); set role authenticated;
select pg_temp.ck('vendor sees charges+notes of its own bookings only', (select count(*) = 2 from public.service_charges) and (select count(*) = 1 from public.service_booking_notes));
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', false); set role authenticated;
select pg_temp.ck('vendor B sees none of Alpha''s bookings, charges, notes, pickups', (select count(*) from public.service_bookings) = 0 and (select count(*) from public.service_charges) = 0 and (select count(*) from public.pickup_dropoff_requests) = 0);
reset role;

-- ===== invariants =====
select pg_temp.ck('INVARIANT final_price = estimate + sum(charges) wherever charges exist', (select count(*)=0 from public.service_bookings b where exists (select 1 from public.service_charges c where c.booking_id=b.id) and b.final_price <> b.estimated_price + (select sum(amount) from public.service_charges c where c.booking_id=b.id)));
select pg_temp.ck('INVARIANT estimated_price never differs from the vendor service price at booking time', (select count(*)=0 from public.service_bookings where estimated_price <> 499));
select pg_temp.ck('INVARIANT accepted bookings never exceed slot capacity', (select count(*)=0 from (select vendor_service_id, confirmed_date, confirmed_slot_start from public.service_bookings where status='accepted' group by 1,2,3 having count(*) > 1) x));
select pg_temp.ck('INVARIANT completed bookings have completed delivery when a request exists', (select count(*)=0 from public.service_bookings b join public.pickup_dropoff_requests r on r.booking_id=b.id where b.status='completed' and r.delivery_status<>'completed'));
