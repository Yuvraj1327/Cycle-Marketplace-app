-- 08: Row Level Security
-- Model: customers/vendors act on their own rows; admins on everything; the FastAPI backend (service role) bypasses RLS
-- and performs all money-affecting writes (orders, payments, refunds, booking creation, notifications).
-- Policies never subquery a table whose policies subquery back; cross-table checks go through SECURITY DEFINER helpers.

-- ---------- extra helper ----------
-- vendors may see the contact profile of customers they actually deal with (orders / service bookings)
create or replace function public.vendor_can_view_customer(customer uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.vendor_orders vo join public.orders o on o.id = vo.order_id
    where vo.vendor_id = public.current_vendor_id() and o.customer_id = customer
  ) or exists (
    select 1 from public.service_bookings sb
    where sb.vendor_id = public.current_vendor_id() and sb.customer_id = customer
  );
$$;

-- ---------- enable RLS everywhere ----------
alter table public.profiles                enable row level security;
alter table public.user_addresses          enable row level security;
alter table public.vendor_profiles         enable row level security;
alter table public.categories              enable row level security;
alter table public.products                enable row level security;
alter table public.product_images          enable row level security;
alter table public.carts                   enable row level security;
alter table public.cart_items              enable row level security;
alter table public.wishlists               enable row level security;
alter table public.wishlist_items          enable row level security;
alter table public.service_categories      enable row level security;
alter table public.banners                 enable row level security;
alter table public.coupons                 enable row level security;
alter table public.commission_rules        enable row level security;
alter table public.platform_settings       enable row level security;
alter table public.orders                  enable row level security;
alter table public.vendor_orders           enable row level security;
alter table public.order_items             enable row level security;
alter table public.order_status_history    enable row level security;
alter table public.payments                enable row level security;
alter table public.refunds                 enable row level security;
alter table public.vendor_services         enable row level security;
alter table public.service_bookings        enable row level security;
alter table public.service_booking_images  enable row level security;
alter table public.booking_status_history  enable row level security;
alter table public.pickup_dropoff_requests enable row level security;
alter table public.notifications           enable row level security;
alter table public.support_tickets         enable row level security;

-- ---------- profiles ----------
-- no INSERT policy: rows are created only by the auth.users trigger. no DELETE policy: removal cascades from auth.users.
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_admin() or public.vendor_can_view_customer(id));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy profiles_update_admin on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- user_addresses ----------
create policy addresses_owner_all on public.user_addresses for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy addresses_admin_select on public.user_addresses for select to authenticated
  using (public.is_admin());

-- ---------- vendor_profiles (private table; public data is exposed via view vendor_public_profiles) ----------
create policy vendor_profiles_select on public.vendor_profiles for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());
create policy vendor_profiles_insert_own on public.vendor_profiles for insert to authenticated
  with check (user_id = (select auth.uid()) and public.current_user_role() = 'vendor' and public.is_active_user());
create policy vendor_profiles_update_own on public.vendor_profiles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy vendor_profiles_admin_all on public.vendor_profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- categories / service_categories ----------
create policy categories_public_select on public.categories for select to anon, authenticated
  using (is_active or public.is_admin());
create policy categories_admin_write on public.categories for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy service_categories_public_select on public.service_categories for select to anon, authenticated
  using (is_active or public.is_admin());
create policy service_categories_admin_write on public.service_categories for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- products ----------
create policy products_select on public.products for select to anon, authenticated
  using (
    (is_active and approval_status = 'approved' and public.vendor_is_approved(vendor_id))
    or vendor_id = public.current_vendor_id()
    or public.is_admin()
  );
create policy products_vendor_insert on public.products for insert to authenticated
  with check (vendor_id = public.current_vendor_id() and public.is_approved_vendor());
create policy products_vendor_update on public.products for update to authenticated
  using (vendor_id = public.current_vendor_id() and public.is_approved_vendor())
  with check (vendor_id = public.current_vendor_id() and public.is_approved_vendor());
create policy products_vendor_delete on public.products for delete to authenticated
  using (vendor_id = public.current_vendor_id() and public.is_approved_vendor());
create policy products_admin_all on public.products for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- product_images: visible whenever the parent product is visible (the subquery is itself subject to products RLS)
create policy product_images_select on public.product_images for select to anon, authenticated
  using (exists (select 1 from public.products p where p.id = product_id));
create policy product_images_vendor_write on public.product_images for all to authenticated
  using (public.is_approved_vendor() and exists (select 1 from public.products p where p.id = product_id and p.vendor_id = public.current_vendor_id()))
  with check (public.is_approved_vendor() and exists (select 1 from public.products p where p.id = product_id and p.vendor_id = public.current_vendor_id()));
create policy product_images_admin_all on public.product_images for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- carts & wishlists ----------
create policy carts_owner_all on public.carts for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy cart_items_owner_all on public.cart_items for all to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())))
  with check (
    exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid()))
    and exists (select 1 from public.products p where p.id = product_id)   -- only products the user may see
  );
create policy wishlists_owner_all on public.wishlists for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy wishlist_items_owner_all on public.wishlist_items for all to authenticated
  using (exists (select 1 from public.wishlists w where w.id = wishlist_id and w.user_id = (select auth.uid())))
  with check (
    exists (select 1 from public.wishlists w where w.id = wishlist_id and w.user_id = (select auth.uid()))
    and exists (select 1 from public.products p where p.id = product_id)
  );

-- ---------- promotions & settings ----------
create policy banners_public_select on public.banners for select to anon, authenticated
  using (
    (is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()))
    or public.is_admin()
  );
create policy banners_admin_write on public.banners for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- coupons are admin-only; customers validate codes through the backend (prevents code enumeration)
create policy coupons_admin_all on public.coupons for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy commission_rules_vendor_select on public.commission_rules for select to authenticated
  using (is_active and (vendor_id is null or vendor_id = public.current_vendor_id()) and public.current_vendor_id() is not null);
create policy commission_rules_admin_all on public.commission_rules for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy platform_settings_public_select on public.platform_settings for select to anon, authenticated
  using (is_public or public.is_admin());
create policy platform_settings_admin_write on public.platform_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- orders (writes: backend/service role only, except vendor fulfilment updates) ----------
create policy orders_select on public.orders for select to authenticated
  using (
    customer_id = (select auth.uid())
    or exists (select 1 from public.vendor_orders vo where vo.order_id = orders.id and vo.vendor_id = public.current_vendor_id())
    or public.is_admin()
  );
create policy orders_admin_write on public.orders for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy vendor_orders_select on public.vendor_orders for select to authenticated
  using (vendor_id = public.current_vendor_id() or public.customer_owns_order(order_id) or public.is_admin());
create policy vendor_orders_vendor_update on public.vendor_orders for update to authenticated
  using (vendor_id = public.current_vendor_id() and public.is_approved_vendor())
  with check (vendor_id = public.current_vendor_id());
create policy vendor_orders_admin_write on public.vendor_orders for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy order_items_select on public.order_items for select to authenticated
  using (
    public.customer_owns_order(order_id)
    or exists (select 1 from public.vendor_orders vo where vo.id = vendor_order_id and vo.vendor_id = public.current_vendor_id())
    or public.is_admin()
  );
create policy order_items_admin_write on public.order_items for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy order_status_history_select on public.order_status_history for select to authenticated
  using (
    public.customer_owns_order(order_id)
    or (vendor_order_id is not null and exists (select 1 from public.vendor_orders vo where vo.id = vendor_order_id and vo.vendor_id = public.current_vendor_id()))
    or public.is_admin()
  );

-- ---------- payments & refunds (customers read only; admin read/manage; writes via backend) ----------
create policy payments_select on public.payments for select to authenticated
  using (customer_id = (select auth.uid()) or public.is_admin());
create policy payments_admin_write on public.payments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy refunds_select on public.refunds for select to authenticated
  using (
    exists (select 1 from public.payments p where p.id = payment_id and p.customer_id = (select auth.uid()))
    or public.is_admin()
  );
create policy refunds_admin_write on public.refunds for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- vendor_services ----------
create policy vendor_services_select on public.vendor_services for select to anon, authenticated
  using (
    (is_active and public.vendor_is_approved(vendor_id))
    or vendor_id = public.current_vendor_id()
    or public.is_admin()
  );
create policy vendor_services_vendor_write on public.vendor_services for all to authenticated
  using (vendor_id = public.current_vendor_id() and public.is_approved_vendor())
  with check (vendor_id = public.current_vendor_id() and public.is_approved_vendor());
create policy vendor_services_admin_all on public.vendor_services for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- service bookings (creation/cancellation/price snapshot via backend) ----------
create policy service_bookings_select on public.service_bookings for select to authenticated
  using (customer_id = (select auth.uid()) or vendor_id = public.current_vendor_id() or public.is_admin());
create policy service_bookings_vendor_update on public.service_bookings for update to authenticated
  using (vendor_id = public.current_vendor_id() and public.is_approved_vendor())
  with check (vendor_id = public.current_vendor_id());
create policy service_bookings_admin_all on public.service_bookings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy booking_images_select on public.service_booking_images for select to authenticated
  using (exists (select 1 from public.service_bookings b where b.id = booking_id));
create policy booking_images_customer_insert on public.service_booking_images for insert to authenticated
  with check (
    uploaded_by = (select auth.uid())
    and exists (select 1 from public.service_bookings b where b.id = booking_id and b.customer_id = (select auth.uid()) and b.status = 'pending')
  );
create policy booking_images_customer_delete on public.service_booking_images for delete to authenticated
  using (
    uploaded_by = (select auth.uid())
    and exists (select 1 from public.service_bookings b where b.id = booking_id and b.customer_id = (select auth.uid()) and b.status = 'pending')
  );
create policy booking_images_admin_all on public.service_booking_images for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy booking_history_select on public.booking_status_history for select to authenticated
  using (exists (select 1 from public.service_bookings b where b.id = booking_id));

create policy pickup_dropoff_select on public.pickup_dropoff_requests for select to authenticated
  using (exists (select 1 from public.service_bookings b where b.id = booking_id));
create policy pickup_dropoff_vendor_update on public.pickup_dropoff_requests for update to authenticated
  using (public.is_approved_vendor() and exists (select 1 from public.service_bookings b where b.id = booking_id and b.vendor_id = public.current_vendor_id()))
  with check (exists (select 1 from public.service_bookings b where b.id = booking_id and b.vendor_id = public.current_vendor_id()));
create policy pickup_dropoff_admin_all on public.pickup_dropoff_requests for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- notifications ----------
create policy notifications_select_own on public.notifications for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());
create policy notifications_update_own on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy notifications_delete_own on public.notifications for delete to authenticated
  using (user_id = (select auth.uid()));
create policy notifications_admin_all on public.notifications for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- support tickets ----------
create policy support_tickets_select on public.support_tickets for select to authenticated
  using (requester_id = (select auth.uid()) or public.is_admin());
create policy support_tickets_insert_own on public.support_tickets for insert to authenticated
  with check (
    requester_id = (select auth.uid()) and status = 'open' and assigned_to is null
    and admin_notes is null and resolution is null and resolved_at is null and public.is_active_user()
  );
create policy support_tickets_admin_all on public.support_tickets for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- function privileges ----------
-- guard/log trigger functions must not be callable as RPC
revoke execute on function
  public.handle_new_user(), public.guard_profile_update(), public.guard_vendor_profile(), public.guard_product(),
  public.guard_vendor_order(), public.guard_service_booking(), public.guard_pickup_dropoff(), public.guard_notification(),
  public.log_vendor_order_status(), public.log_order_status(), public.log_booking_status()
  from public, anon, authenticated;
