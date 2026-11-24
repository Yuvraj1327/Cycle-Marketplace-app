-- 16: transactional functions for servicing (service_role only; the backend authorises first and passes the actor).
-- Business errors:  'CM:<code>:<detail>'  (SQLSTATE P0001).
-- LOCK ORDER: vendor_profiles (capacity) -> service_bookings -> pickup_dropoff_requests.
--
-- COMPLETION OF LOGISTICS IS RECORDED BY THE BOOKING STATUS (single path, no contradictory states):
--   booking -> picked_up  records pickup completion;  booking -> completed records delivery completion;
--   cancelled / rejected  cancels any logistics step not yet completed.
-- The coordination function (set_service_logistics) only schedules, reschedules, marks an attempt failed or cancels.

-- one notification per (user, event_key); repeats are silently ignored
create or replace function public.cm_notify_once(p_user uuid, p_type public.notification_type, p_title text, p_message text, p_related_type text, p_related_id uuid, p_event_key text)
returns void language sql security definer set search_path = ''
as $$
  insert into public.notifications (user_id, type, title, message, related_type, related_id, event_key)
  select p_user, p_type, p_title, p_message, p_related_type, p_related_id, p_event_key where p_user is not null
  on conflict (user_id, event_key) where event_key is not null do nothing;
$$;

create or replace function public.cm_notify_admins_once(p_type public.notification_type, p_title text, p_message text, p_related_type text, p_related_id uuid, p_event_key text)
returns void language sql security definer set search_path = ''
as $$
  insert into public.notifications (user_id, type, title, message, related_type, related_id, event_key)
  select id, p_type, p_title, p_message, p_related_type, p_related_id, p_event_key from public.profiles where role = 'admin' and status = 'active'
  on conflict (user_id, event_key) where event_key is not null do nothing;
$$;

-- ---------------------------------------------------------------------------------------------------------------- create
create or replace function public.create_service_booking(p jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_customer uuid := (p ->> 'customer_id')::uuid;
  v_needs boolean := coalesce((p ->> 'needs_pickup_dropoff')::boolean, false);
  vs public.vendor_services; vp public.vendor_profiles; cat public.service_categories; b public.service_bookings;
begin
  perform public.cm_set_actor(v_customer, 'customer', null);
  if not exists (select 1 from public.profiles where id = v_customer and role = 'customer' and status = 'active') then
    raise exception 'CM:account_inactive:' using errcode = 'P0001';
  end if;
  select * into vs from public.vendor_services where id = (p ->> 'service_id')::uuid for share;
  if not found or not vs.is_active or not vs.is_available then raise exception 'CM:service_unavailable:' using errcode = 'P0001'; end if;
  if not public.vendor_is_approved(vs.vendor_id) then raise exception 'CM:vendor_unavailable:' using errcode = 'P0001'; end if;
  select * into cat from public.service_categories where id = vs.service_category_id;
  if not cat.is_active then raise exception 'CM:service_unavailable:' using errcode = 'P0001'; end if;
  select * into vp from public.vendor_profiles where id = vs.vendor_id;
  if v_needs and not vp.pickup_available then raise exception 'CM:pickup_not_offered:' using errcode = 'P0001'; end if;

  begin
    insert into public.service_bookings (customer_id, vendor_id, vendor_service_id, service_name, service_category_id, vendor_name, cycle_brand, cycle_model, cycle_details,
                                         issue_description, preferred_date, preferred_slot_start, preferred_slot_end, needs_pickup_dropoff, estimated_price, estimated_duration_minutes)
    values (v_customer, vs.vendor_id, vs.id, vs.name, vs.service_category_id, vp.business_name, nullif(p ->> 'cycle_brand', ''), nullif(p ->> 'cycle_model', ''),
            nullif(p ->> 'cycle_details', ''), p ->> 'issue_description', (p ->> 'preferred_date')::date, (p ->> 'slot_start')::time, (p ->> 'slot_end')::time,
            v_needs, vs.price, vs.estimated_duration_minutes)           -- the price is read HERE from the database, never from the request
    returning * into b;
  exception when unique_violation then
    raise exception 'CM:duplicate_booking:' using errcode = 'P0001';
  end;

  if v_needs then
    insert into public.pickup_dropoff_requests (booking_id, pickup_address_id, pickup_address, dropoff_address_id, dropoff_address, pickup_charge, dropoff_charge, customer_instructions)
    values (b.id, nullif(p ->> 'pickup_address_id', '')::uuid, p -> 'pickup_address', nullif(p ->> 'dropoff_address_id', '')::uuid, p -> 'dropoff_address',
            coalesce((p ->> 'pickup_charge')::numeric, 0), coalesce((p ->> 'dropoff_charge')::numeric, 0), nullif(p ->> 'customer_instructions', ''));
  end if;

  perform public.cm_notify_once(v_customer, 'service_booking', 'Booking received', 'Your booking ' || b.booking_number || ' for ' || b.service_name || ' was sent to ' || vp.business_name || '.', 'service_booking', b.id, 'booking:' || b.id || ':created');
  perform public.cm_notify_once(vp.user_id, 'service_booking', 'New service booking', 'New booking ' || b.booking_number || ' (' || b.service_name || ') is waiting for your response.', 'service_booking', b.id, 'booking:' || b.id || ':created');
  perform public.cm_notify_admins_once('service_booking', 'New service request', 'Booking ' || b.booking_number || ' was created with ' || vp.business_name || '.', 'service_booking', b.id, 'booking:' || b.id || ':created');
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number);
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------- accept / reschedule
-- Capacity: at most service.max_bookings_per_slot ACCEPTED bookings of the same service in the same confirmed slot. The vendor row is locked,
-- so two simultaneous accepts cannot both take the last place.
create or replace function public.cm_confirm_slot(p_booking uuid, p_date date, p_start time, p_end time)
returns void language plpgsql security definer set search_path = ''
as $$
declare b public.service_bookings; cap int; taken int;
begin
  select * into b from public.service_bookings where id = p_booking;
  select coalesce(max(max_bookings_per_slot), 1) into cap from public.vendor_services where id = b.vendor_service_id;
  select count(*) into taken from public.service_bookings
   where vendor_service_id = b.vendor_service_id and status = 'accepted' and id <> b.id
     and confirmed_date = p_date and confirmed_slot_start = p_start;
  if taken >= cap then raise exception 'CM:slot_full:%', p_date || ' ' || p_start using errcode = 'P0001'; end if;
  update public.service_bookings set confirmed_date = p_date, confirmed_slot_start = p_start, confirmed_slot_end = p_end where id = p_booking;
end;
$$;

create or replace function public.accept_service_booking(p_booking uuid, p_vendor uuid, p_actor uuid, p_date date, p_start time, p_end time, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare b public.service_bookings;
begin
  perform public.cm_set_actor(p_actor, 'vendor', p_note);
  select * into b from public.service_bookings where id = p_booking;
  if not found or b.vendor_id is distinct from p_vendor then raise exception 'CM:not_found:booking' using errcode = 'P0001'; end if;
  perform 1 from public.vendor_profiles where id = b.vendor_id for update;                   -- serialise capacity decisions per vendor
  select * into b from public.service_bookings where id = p_booking for update;
  if b.status <> 'pending' then raise exception 'CM:invalid_transition:%>accepted', b.status using errcode = 'P0001'; end if;
  perform public.cm_confirm_slot(p_booking, coalesce(p_date, b.preferred_date), coalesce(p_start, b.preferred_slot_start), coalesce(p_end, b.preferred_slot_end));
  update public.service_bookings set status = 'accepted' where id = p_booking;
  select * into b from public.service_bookings where id = p_booking;
  perform public.cm_notify_once(b.customer_id, 'service_booking', 'Booking accepted',
          b.vendor_name || ' accepted booking ' || b.booking_number || ' for ' || b.confirmed_date || ' at ' || to_char(b.confirmed_slot_start, 'HH24:MI') || '.', 'service_booking', b.id, 'booking:' || b.id || ':status:accepted');
  return jsonb_build_object('booking_id', b.id, 'status', b.status, 'confirmed_date', b.confirmed_date, 'confirmed_slot_start', b.confirmed_slot_start);
end;
$$;

create or replace function public.reschedule_service_booking(p_booking uuid, p_vendor uuid, p_actor uuid, p_role text, p_date date, p_start time, p_end time, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare b public.service_bookings;
begin
  perform public.cm_set_actor(p_actor, p_role, p_note);
  select * into b from public.service_bookings where id = p_booking;
  if not found or (p_vendor is not null and b.vendor_id is distinct from p_vendor) then raise exception 'CM:not_found:booking' using errcode = 'P0001'; end if;
  perform 1 from public.vendor_profiles where id = b.vendor_id for update;
  select * into b from public.service_bookings where id = p_booking for update;
  if b.status <> 'accepted' then raise exception 'CM:invalid_transition:%>reschedule', b.status using errcode = 'P0001'; end if;
  perform public.cm_confirm_slot(p_booking, p_date, p_start, p_end);
  select * into b from public.service_bookings where id = p_booking;
  perform public.cm_notify_once(b.customer_id, 'service_booking', 'Appointment rescheduled', 'Booking ' || b.booking_number || ' is now ' || b.confirmed_date || ' at ' || to_char(b.confirmed_slot_start, 'HH24:MI') || '.',
          'service_booking', b.id, 'booking:' || b.id || ':rescheduled:' || b.confirmed_date || ':' || b.confirmed_slot_start);
  return jsonb_build_object('booking_id', b.id, 'confirmed_date', b.confirmed_date, 'confirmed_slot_start', b.confirmed_slot_start);
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------- status machine
create or replace function public.transition_service_booking(p_booking uuid, p_vendor uuid, p_status public.booking_status, p_actor uuid, p_role text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare b public.service_bookings; ok boolean; vp_user uuid; label text;
begin
  perform public.cm_set_actor(p_actor, p_role, p_note);
  select * into b from public.service_bookings where id = p_booking;
  if not found or (p_vendor is not null and b.vendor_id is distinct from p_vendor) or (p_role = 'customer' and b.customer_id is distinct from p_actor) then
    raise exception 'CM:not_found:booking' using errcode = 'P0001';
  end if;
  select * into b from public.service_bookings where id = p_booking for update;
  if p_status = 'accepted' then raise exception 'CM:use_accept:' using errcode = 'P0001'; end if;
  if p_status in ('rejected', 'cancelled') and coalesce(btrim(p_note), '') = '' then raise exception 'CM:reason_required:' using errcode = 'P0001'; end if;

  ok := case
    when p_role = 'customer' then p_status = 'cancelled' and b.status in ('pending', 'accepted')
    when p_status = 'rejected' then b.status = 'pending'
    when p_status = 'cancelled' then (b.status = 'accepted') or (p_role = 'admin' and b.status in ('pending', 'picked_up', 'in_service', 'ready_for_delivery'))
    when p_status = 'picked_up' then b.status = 'accepted' and b.needs_pickup_dropoff
    when p_status = 'in_service' then (b.status = 'accepted' and not b.needs_pickup_dropoff) or b.status = 'picked_up'
    when p_status = 'ready_for_delivery' then b.status = 'in_service'
    when p_status = 'completed' then b.status = 'ready_for_delivery'
    else false end;
  if not ok then raise exception 'CM:invalid_transition:%>%', b.status, p_status using errcode = 'P0001'; end if;

  update public.service_bookings
     set status = p_status,
         rejection_reason = case when p_status = 'rejected' then p_note else rejection_reason end,
         cancellation_reason = case when p_status = 'cancelled' then p_note else cancellation_reason end,
         cancelled_by = case when p_status = 'cancelled' then p_actor else cancelled_by end,
         completion_notes = case when p_status = 'completed' then coalesce(nullif(btrim(p_note), ''), completion_notes) else completion_notes end,
         confirmed_date = case when p_status in ('rejected', 'cancelled') then null else confirmed_date end,
         confirmed_slot_start = case when p_status in ('rejected', 'cancelled') then null else confirmed_slot_start end,
         confirmed_slot_end = case when p_status in ('rejected', 'cancelled') then null else confirmed_slot_end end
   where id = p_booking;

  if p_status = 'picked_up' then
    update public.pickup_dropoff_requests set pickup_status = 'completed' where booking_id = p_booking and pickup_status <> 'completed' and pickup_status <> 'cancelled';
  elsif p_status = 'completed' then
    update public.pickup_dropoff_requests set delivery_status = 'completed' where booking_id = p_booking and delivery_status <> 'completed' and delivery_status <> 'cancelled';
  elsif p_status in ('rejected', 'cancelled') then
    update public.pickup_dropoff_requests set pickup_status = case when pickup_status = 'completed' then pickup_status else 'cancelled' end,
                                              delivery_status = case when delivery_status = 'completed' then delivery_status else 'cancelled' end
     where booking_id = p_booking;
  end if;

  select user_id into vp_user from public.vendor_profiles where id = b.vendor_id;
  label := case p_status when 'rejected' then 'Booking rejected' when 'picked_up' then 'Cycle picked up' when 'in_service' then 'Repair started'
                         when 'ready_for_delivery' then 'Ready for delivery' when 'completed' then 'Service completed' when 'cancelled' then 'Booking cancelled' end;
  if p_status = 'cancelled' then
    if p_role <> 'customer' then
      perform public.cm_notify_once(b.customer_id, 'service_booking', label, 'Booking ' || b.booking_number || ' was cancelled: ' || p_note, 'service_booking', b.id, 'booking:' || b.id || ':status:cancelled');
    end if;
    if p_role <> 'vendor' then
      perform public.cm_notify_once(vp_user, 'service_booking', label, 'Booking ' || b.booking_number || ' was cancelled: ' || p_note, 'service_booking', b.id, 'booking:' || b.id || ':status:cancelled');
    end if;
    if p_role <> 'admin' then
      perform public.cm_notify_admins_once('service_booking', label, 'Booking ' || b.booking_number || ' was cancelled by the ' || p_role || '.', 'service_booking', b.id, 'booking:' || b.id || ':status:cancelled');
    end if;
  else
    perform public.cm_notify_once(b.customer_id, case when p_status in ('picked_up', 'completed') then 'pickup_delivery'::public.notification_type else 'service_booking'::public.notification_type end,
            label, 'Booking ' || b.booking_number || ': ' || lower(label) || coalesce(' (' || nullif(btrim(p_note), '') || ')', '') || '.', 'service_booking', b.id, 'booking:' || b.id || ':status:' || p_status);
  end if;
  return jsonb_build_object('booking_id', p_booking, 'status', p_status);
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------- charges & notes
-- Additional repair charges are APPENDED (never overwrite the estimate). final_price = estimated_price + sum(charges). Nothing is charged here.
create or replace function public.add_service_charge(p_booking uuid, p_vendor uuid, p_actor uuid, p_role text, p_amount numeric, p_reason text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare b public.service_bookings; cid uuid; new_final numeric;
begin
  perform public.cm_set_actor(p_actor, p_role, null);
  select * into b from public.service_bookings where id = p_booking;
  if not found or (p_vendor is not null and b.vendor_id is distinct from p_vendor) then raise exception 'CM:not_found:booking' using errcode = 'P0001'; end if;
  select * into b from public.service_bookings where id = p_booking for update;
  if b.status not in ('accepted', 'picked_up', 'in_service', 'ready_for_delivery') then raise exception 'CM:charge_not_allowed:%', b.status using errcode = 'P0001'; end if;
  if p_amount is null or p_amount = 0 then raise exception 'CM:invalid_amount:' using errcode = 'P0001'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'CM:reason_required:' using errcode = 'P0001'; end if;
  new_final := coalesce(b.final_price, b.estimated_price) + p_amount;
  if new_final < 0 then raise exception 'CM:final_negative:' using errcode = 'P0001'; end if;
  insert into public.service_charges (booking_id, amount, reason, recorded_by, recorded_role) values (p_booking, p_amount, p_reason, p_actor, p_role) returning id into cid;
  update public.service_bookings set final_price = new_final, price_change_reason = p_reason where id = p_booking;
  perform public.cm_notify_once(b.customer_id, 'service_booking', 'Repair charge updated',
          'Booking ' || b.booking_number || ': ' || case when p_amount > 0 then 'additional charge of ' else 'adjustment of ' end || p_amount || ' (' || p_reason || '). New total: ' || new_final || '.',
          'service_booking', b.id, 'booking:' || b.id || ':charge:' || cid);
  return jsonb_build_object('charge_id', cid, 'estimated_price', b.estimated_price, 'final_price', new_final);
end;
$$;

create or replace function public.add_service_note(p_booking uuid, p_vendor uuid, p_actor uuid, p_role text, p_note text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare b public.service_bookings; nid uuid;
begin
  select * into b from public.service_bookings where id = p_booking;
  if not found or (p_vendor is not null and b.vendor_id is distinct from p_vendor) then raise exception 'CM:not_found:booking' using errcode = 'P0001'; end if;
  insert into public.service_booking_notes (booking_id, author_id, author_role, note) values (p_booking, p_actor, p_role, p_note) returning id into nid;
  update public.service_bookings set vendor_notes = p_note where id = p_booking and p_role = 'vendor';
  return nid;
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------- logistics coordination
create or replace function public.set_service_logistics(p_request uuid, p_vendor uuid, p_actor uuid, p_role text, p jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r public.pickup_dropoff_requests; b public.service_bookings; v_pickup public.logistics_status; v_delivery public.logistics_status;
  v_pat timestamptz; v_dat timestamptz;
begin
  perform public.cm_set_actor(p_actor, p_role, p ->> 'notes');
  select * into r from public.pickup_dropoff_requests where id = p_request;
  if not found then raise exception 'CM:not_found:pickup_request' using errcode = 'P0001'; end if;
  select * into b from public.service_bookings where id = r.booking_id;
  if p_vendor is not null and b.vendor_id is distinct from p_vendor then raise exception 'CM:not_found:pickup_request' using errcode = 'P0001'; end if;
  select * into b from public.service_bookings where id = r.booking_id for update;
  select * into r from public.pickup_dropoff_requests where id = p_request for update;
  if b.status in ('rejected', 'cancelled', 'completed') or (p_role = 'vendor' and b.status = 'pending') then
    raise exception 'CM:invalid_transition:booking_%', b.status using errcode = 'P0001';
  end if;

  v_pickup := coalesce(nullif(p ->> 'pickup_status', '')::public.logistics_status, r.pickup_status);
  v_delivery := coalesce(nullif(p ->> 'delivery_status', '')::public.logistics_status, r.delivery_status);
  v_pat := case when p ? 'scheduled_pickup_at' then nullif(p ->> 'scheduled_pickup_at', '')::timestamptz else r.scheduled_pickup_at end;
  v_dat := case when p ? 'scheduled_delivery_at' then nullif(p ->> 'scheduled_delivery_at', '')::timestamptz else r.scheduled_delivery_at end;

  if v_pickup is distinct from r.pickup_status then
    if v_pickup = 'completed' then raise exception 'CM:use_booking_status:pickup' using errcode = 'P0001'; end if;
    if not ((r.pickup_status in ('pending', 'scheduled') and v_pickup in ('scheduled', 'failed', 'cancelled')) or (r.pickup_status = 'failed' and v_pickup in ('scheduled', 'cancelled'))) then
      raise exception 'CM:invalid_transition:pickup_%>%', r.pickup_status, v_pickup using errcode = 'P0001';
    end if;
  end if;
  if v_delivery is distinct from r.delivery_status then
    if v_delivery = 'completed' then raise exception 'CM:use_booking_status:delivery' using errcode = 'P0001'; end if;
    if not ((r.delivery_status in ('pending', 'scheduled') and v_delivery in ('scheduled', 'failed', 'cancelled')) or (r.delivery_status = 'failed' and v_delivery in ('scheduled', 'cancelled'))) then
      raise exception 'CM:invalid_transition:delivery_%>%', r.delivery_status, v_delivery using errcode = 'P0001';
    end if;
  end if;
  if v_pickup = 'scheduled' and v_pat is null then raise exception 'CM:schedule_required:pickup' using errcode = 'P0001'; end if;
  if v_delivery = 'scheduled' and v_dat is null then raise exception 'CM:schedule_required:delivery' using errcode = 'P0001'; end if;

  update public.pickup_dropoff_requests
     set pickup_status = v_pickup, delivery_status = v_delivery, scheduled_pickup_at = v_pat, scheduled_delivery_at = v_dat,
         notes = case when p ? 'notes' then nullif(p ->> 'notes', '') else notes end
   where id = p_request;

  if v_pickup is distinct from r.pickup_status or v_pat is distinct from r.scheduled_pickup_at then
    perform public.cm_notify_once(b.customer_id, 'pickup_delivery', case v_pickup when 'failed' then 'Pickup attempt failed' when 'cancelled' then 'Pickup cancelled' else 'Pickup scheduled' end,
            'Booking ' || b.booking_number || ': pickup ' || case v_pickup when 'scheduled' then 'is scheduled for ' || coalesce(v_pat::text, '') else v_pickup::text end || '.',
            'pickup_dropoff', p_request, 'pickup:' || p_request || ':' || v_pickup || ':' || coalesce(v_pat::text, ''));
  end if;
  if v_delivery is distinct from r.delivery_status or v_dat is distinct from r.scheduled_delivery_at then
    perform public.cm_notify_once(b.customer_id, 'pickup_delivery', case v_delivery when 'failed' then 'Delivery attempt failed' when 'cancelled' then 'Delivery cancelled' else 'Return delivery scheduled' end,
            'Booking ' || b.booking_number || ': return delivery ' || case v_delivery when 'scheduled' then 'is scheduled for ' || coalesce(v_dat::text, '') else v_delivery::text end || '.',
            'pickup_dropoff', p_request, 'delivery:' || p_request || ':' || v_delivery || ':' || coalesce(v_dat::text, ''));
  end if;
  return jsonb_build_object('request_id', p_request, 'pickup_status', v_pickup, 'delivery_status', v_delivery);
end;
$$;

revoke execute on function
  public.cm_notify_once(uuid, public.notification_type, text, text, text, uuid, text), public.cm_notify_admins_once(public.notification_type, text, text, text, uuid, text),
  public.create_service_booking(jsonb), public.cm_confirm_slot(uuid, date, time, time),
  public.accept_service_booking(uuid, uuid, uuid, date, time, time, text), public.reschedule_service_booking(uuid, uuid, uuid, text, date, time, time, text),
  public.transition_service_booking(uuid, uuid, public.booking_status, uuid, text, text), public.add_service_charge(uuid, uuid, uuid, text, numeric, text),
  public.add_service_note(uuid, uuid, uuid, text, text), public.set_service_logistics(uuid, uuid, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.create_service_booking(jsonb), public.accept_service_booking(uuid, uuid, uuid, date, time, time, text),
  public.reschedule_service_booking(uuid, uuid, uuid, text, date, time, time, text), public.transition_service_booking(uuid, uuid, public.booking_status, uuid, text, text),
  public.add_service_charge(uuid, uuid, uuid, text, numeric, text), public.add_service_note(uuid, uuid, uuid, text, text), public.set_service_logistics(uuid, uuid, uuid, text, jsonb)
  to service_role;
