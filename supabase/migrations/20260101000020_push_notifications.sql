-- 20: Push notification infrastructure (Step 11).
--  * device_tokens: FCM registration tokens. RLS is on and there are NO policies and no table privileges for anon/authenticated, so a token can never be read or
--    written from a client; only the backend (service role) touches this table, through the functions below.
--  * Push OUTBOX on the existing notifications table (no second notification system): every notification row is created inside the business transaction
--    that caused it (push_status = 'pending'), so a notification exists only if the transaction committed. A backend dispatcher claims pending rows with
--    FOR UPDATE SKIP LOCKED (no duplicate sends, safe with several workers), calls the push provider AFTER the commit, and records the outcome.
--    A failed or unavailable provider never affects the order / booking: the row just stays pending (retried with back-off) or ends 'failed'.
--  * Triggers for two events that had no notification: a vendor order cancelled by someone else (customer / admin) and a product approved / rejected.
--  * admin_announcement_stats now reports push outcomes; admin_push_status summarises the outbox.
--  * Storage tightening found by the Step 11 policy tests: only CUSTOMER accounts may write to the private `service-images` bucket (the old policy let any signed-in
--    role write into its own <uid>/ folder). Reads are unchanged. Nothing is loosened.
-- All functions below are service_role only.

create table public.device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  token        text not null check (char_length(token) between 20 and 4096),
  platform     text not null check (platform in ('android', 'ios', 'web')),
  app          text not null check (app in ('customer', 'vendor')),
  device_label text check (device_label is null or char_length(device_label) <= 100),
  app_version  text check (app_version is null or char_length(app_version) <= 30),
  is_active    boolean not null default true,
  last_error   text,
  last_seen_at timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index device_tokens_token_key on public.device_tokens (token);
create index device_tokens_user_idx on public.device_tokens (user_id) where is_active;
create trigger device_tokens_set_updated_at before update on public.device_tokens
  for each row execute function public.set_updated_at();
alter table public.device_tokens enable row level security;
revoke all on public.device_tokens from anon, authenticated;

-- Register (or take over) a token for a user. One physical token = one row: if the same phone signs in as someone else, the token moves to them, so
-- the previous user stops receiving that person's notifications. A user keeps at most 10 active devices (the most recently seen).
create or replace function public.register_device_token(p_user uuid, p_token text, p_platform text, p_app text, p_label text, p_version text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  insert into public.device_tokens (user_id, token, platform, app, device_label, app_version)
  values (p_user, p_token, p_platform, p_app, nullif(btrim(p_label), ''), nullif(btrim(p_version), ''))
  on conflict (token) do update
     set user_id = excluded.user_id, platform = excluded.platform, app = excluded.app, device_label = excluded.device_label,
         app_version = excluded.app_version, is_active = true, last_error = null, last_seen_at = now()
  returning id into v_id;
  update public.device_tokens set is_active = false, last_error = 'replaced by a newer device'
   where user_id = p_user and is_active
     and id not in (select id from public.device_tokens where user_id = p_user and is_active order by last_seen_at desc, created_at desc limit 10);
  return v_id;
end;
$$;

-- Only the owner can unregister (a different user's token is left alone).
create or replace function public.deactivate_device_token(p_user uuid, p_token text)
returns integer language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  update public.device_tokens set is_active = false, last_error = 'signed out'
   where token = p_token and user_id = p_user and is_active;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ------------------------------------------------------------------ push outbox on notifications
alter table public.notifications
  add column push_status   text not null default 'skipped' check (push_status in ('pending', 'sending', 'sent', 'failed', 'skipped', 'expired')),
  add column push_attempts integer not null default 0,
  add column push_next_at  timestamptz not null default now(),
  add column push_sent_at  timestamptz,
  add column push_error    text;
alter table public.notifications alter column push_status set default 'pending';     -- rows that already exist stay 'skipped': history is never pushed
create index notifications_push_queue_idx on public.notifications (push_next_at) where push_status in ('pending', 'sending');

-- recipients may only change the read state; the push columns belong to the backend too
create or replace function public.guard_notification()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_privileged() then
    if new.user_id <> old.user_id or new.type <> old.type or new.title <> old.title
       or new.message <> old.message or new.related_type is distinct from old.related_type
       or new.related_id is distinct from old.related_id or new.created_by is distinct from old.created_by
       or new.push_status is distinct from old.push_status or new.push_attempts is distinct from old.push_attempts
       or new.push_next_at is distinct from old.push_next_at or new.push_sent_at is distinct from old.push_sent_at
       or new.push_error is distinct from old.push_error or new.announcement_id is distinct from old.announcement_id then
      raise exception 'only the read state of a notification can be changed' using errcode = '42501';
    end if;
  end if;
  if new.is_read and not old.is_read then new.read_at := coalesce(new.read_at, now()); end if;
  if not new.is_read then new.read_at := null; end if;
  return new;
end;
$$;

-- Claim up to p_limit due notifications (and their recipient's ACTIVE device tokens) for sending.
--   * rows older than p_max_age are expired (a late push about an old event is worse than none);
--   * rows that already used p_max_attempts are failed;
--   * a claimed row is leased for 5 minutes (push_next_at): if the worker dies it becomes claimable again;
--   * rows of inactive accounts are skipped.
create or replace function public.claim_pending_pushes(p_limit integer, p_max_attempts integer, p_max_age interval)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  update public.notifications set push_status = 'expired', push_error = 'too old to push'
   where push_status in ('pending', 'sending') and created_at < now() - p_max_age;
  update public.notifications set push_status = 'failed', push_error = coalesce(push_error, 'gave up after repeated attempts')
   where push_status in ('pending', 'sending') and push_next_at <= now() and push_attempts >= p_max_attempts;
  update public.notifications n set push_status = 'skipped', push_error = 'recipient account is not active'
   where n.push_status = 'pending' and n.push_next_at <= now()
     and not exists (select 1 from public.profiles p where p.id = n.user_id and p.status = 'active');

  with picked as (
    select id from public.notifications
     where push_status in ('pending', 'sending') and push_next_at <= now()
     order by created_at, id for update skip locked limit greatest(p_limit, 0)),
  claimed as (
    update public.notifications n set push_status = 'sending', push_attempts = n.push_attempts + 1, push_next_at = now() + interval '5 minutes'
      from picked where n.id = picked.id returning n.*)
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'user_id', c.user_id, 'type', c.type, 'title', c.title, 'message', c.message, 'related_type', c.related_type, 'related_id', c.related_id,
      'attempts', c.push_attempts,
      'tokens', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'token', t.token, 'platform', t.platform, 'app', t.app) order by t.last_seen_at desc), '[]'::jsonb)
                   from public.device_tokens t where t.user_id = c.user_id and t.is_active)) order by c.created_at), '[]'::jsonb)
    into v from claimed c;
  return v;
end;
$$;

-- Record the outcome of one claimed notification. p_status: sent | failed | skipped | pending (= retry in p_retry_seconds).
-- Tokens the provider reported as invalid are deactivated so they are never used again.
create or replace function public.finish_push(p_id uuid, p_status text, p_error text, p_retry_seconds integer, p_invalid_token_ids uuid[])
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if p_status not in ('sent', 'failed', 'skipped', 'pending') then
    raise exception 'CM:invalid_push_status' using errcode = 'P0001';
  end if;
  if p_invalid_token_ids is not null and cardinality(p_invalid_token_ids) > 0 then
    update public.device_tokens set is_active = false, last_error = 'rejected by the push provider' where id = any (p_invalid_token_ids);
  end if;
  update public.notifications
     set push_status = p_status, push_error = left(p_error, 300),
         push_sent_at = case when p_status = 'sent' then now() else push_sent_at end,
         push_next_at = case when p_status = 'pending' then now() + make_interval(secs => greatest(coalesce(p_retry_seconds, 60), 1)) else push_next_at end
   where id = p_id and push_status = 'sending';
end;
$$;

-- Outbox summary for the admin console.
create or replace function public.admin_push_status()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'by_status', coalesce((select jsonb_object_agg(push_status, n) from (select push_status, count(*) n from public.notifications where created_at > now() - interval '7 days' group by 1) s), '{}'::jsonb),
    'active_devices', coalesce((select jsonb_object_agg(app, n) from (select app, count(*) n from public.device_tokens where is_active group by 1) d), '{}'::jsonb),
    'oldest_pending', (select min(created_at) from public.notifications where push_status = 'pending'),
    'recent_failures', coalesce((select jsonb_agg(f) from (select id, title, push_error, push_attempts, created_at from public.notifications where push_status = 'failed' order by created_at desc limit 5) f), '[]'::jsonb));
$$;

-- announcements: also report push outcomes
create or replace function public.admin_announcement_stats(p_ids uuid[])
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_object_agg(s.announcement_id, jsonb_build_object('delivered', s.n, 'read', s.r, 'push_sent', s.ps, 'push_failed', s.pf, 'push_pending', s.pp)), '{}'::jsonb)
    from (select announcement_id, count(*) n, count(*) filter (where is_read) r,
                 count(*) filter (where push_status = 'sent') ps, count(*) filter (where push_status in ('failed', 'expired')) pf,
                 count(*) filter (where push_status in ('pending', 'sending')) pp
            from public.notifications where announcement_id = any (p_ids) group by announcement_id) s;
$$;

-- ------------------------------------------------------------------ missing business events
-- A vendor whose order was cancelled by the customer or an administrator is told (the vendor's own cancellations are not echoed back; orders that were never
-- released to the vendor, e.g. unpaid online orders that expired, are not announced).
create or replace function public.notify_vendor_order_cancelled()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_user uuid; v_order text;
begin
  select user_id into v_user from public.vendor_profiles where id = new.vendor_id;
  if new.released_at is not null and new.cancelled_by is distinct from v_user then
    select order_number into v_order from public.orders where id = new.order_id;
    perform public.cm_notify_once(v_user, 'order', 'Order cancelled',
            'Order ' || new.vendor_order_number || ' (' || coalesce(v_order, '') || ') was cancelled' || coalesce(': ' || nullif(btrim(new.cancellation_reason), ''), '') || '.',
            'vendor_order', new.id, 'vo:' || new.id || ':cancelled');
  end if;
  return null;
end;
$$;
create trigger vendor_orders_notify_cancelled after update of status on public.vendor_orders
  for each row when (new.status = 'cancelled' and old.status is distinct from 'cancelled') execute function public.notify_vendor_order_cancelled();

-- The vendor is told when an administrator approves or rejects a listing.
create or replace function public.notify_product_moderation()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_user uuid;
begin
  select user_id into v_user from public.vendor_profiles where id = new.vendor_id;
  perform public.cm_notify(v_user, 'system',
          case new.approval_status when 'approved' then 'Product approved' else 'Product rejected' end,
          '"' || new.name || '" was ' || new.approval_status::text || case when new.approval_status = 'rejected' then coalesce(': ' || nullif(btrim(new.review_notes), ''), '') else ' and can now be shown to customers' end || '.',
          'product', new.id);
  return null;
end;
$$;
create trigger products_notify_moderation after update of approval_status on public.products
  for each row when (new.approval_status in ('approved', 'rejected') and old.approval_status is distinct from new.approval_status) execute function public.notify_product_moderation();

revoke execute on function public.register_device_token(uuid, text, text, text, text, text), public.deactivate_device_token(uuid, text),
  public.claim_pending_pushes(integer, integer, interval), public.finish_push(uuid, text, text, integer, uuid[]), public.admin_push_status(),
  public.admin_announcement_stats(uuid[]) from public, anon, authenticated;
grant execute on function public.register_device_token(uuid, text, text, text, text, text), public.deactivate_device_token(uuid, text),
  public.claim_pending_pushes(integer, integer, interval), public.finish_push(uuid, text, text, integer, uuid[]), public.admin_push_status(),
  public.admin_announcement_stats(uuid[]) to service_role;

-- ------------------------------------------------------------------ storage: cycle photos are uploaded by customers only
drop policy if exists service_images_customer_all on storage.objects;
create policy service_images_customer_all on storage.objects for all to authenticated
  using (bucket_id = 'service-images' and (storage.foldername(name))[1] = (select auth.uid())::text and public.current_user_role() = 'customer')
  with check (bucket_id = 'service-images' and (storage.foldername(name))[1] = (select auth.uid())::text and public.current_user_role() = 'customer');
