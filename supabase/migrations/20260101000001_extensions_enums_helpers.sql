-- 01: extensions, enum types, generic helpers
create extension if not exists pgcrypto with schema extensions;

-- ---------- Enums ----------
create type public.user_role            as enum ('customer', 'vendor', 'admin');
create type public.account_status       as enum ('active', 'inactive', 'restricted');
create type public.address_type         as enum ('delivery', 'pickup', 'both');
create type public.vendor_verification_status as enum ('pending', 'approved', 'rejected', 'suspended');
create type public.vendor_business_type as enum ('bicycle_shop', 'used_cycle_seller', 'spare_parts_seller', 'service_provider');

create type public.category_kind        as enum ('new_cycle', 'used_cycle', 'spare_part', 'accessory');
create type public.product_condition    as enum ('new', 'used');
create type public.listing_status       as enum ('pending', 'approved', 'rejected');

create type public.discount_type        as enum ('percentage', 'fixed');
create type public.coupon_scope         as enum ('products', 'services', 'all');
create type public.commission_scope     as enum ('product', 'service');

create type public.payment_method       as enum ('online', 'cod');
create type public.payment_status       as enum ('pending', 'successful', 'failed', 'cancelled');
create type public.refund_status        as enum ('requested', 'approved', 'processed', 'rejected', 'failed');
create type public.order_status         as enum ('pending', 'confirmed', 'completed', 'cancelled');
create type public.vendor_order_status  as enum ('pending', 'accepted', 'rejected', 'preparing', 'ready_for_dispatch', 'out_for_delivery', 'delivered', 'cancelled');

create type public.booking_status       as enum ('pending', 'accepted', 'rejected', 'picked_up', 'in_service', 'ready_for_delivery', 'completed', 'cancelled');
create type public.logistics_status     as enum ('pending', 'scheduled', 'completed', 'failed', 'cancelled');

create type public.notification_type    as enum ('order', 'payment', 'service_booking', 'pickup_delivery', 'promotion', 'announcement', 'system');
create type public.support_ticket_type  as enum ('complaint', 'support_request', 'dispute');
create type public.support_ticket_status as enum ('open', 'in_progress', 'resolved', 'closed');

-- ---------- Generic helpers ----------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
