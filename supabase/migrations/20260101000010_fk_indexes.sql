-- 10: indexes for functional foreign keys (audit columns such as created_by/reviewed_by are intentionally left unindexed)
create index commission_rules_vendor_idx           on public.commission_rules (vendor_id) where vendor_id is not null;
create index commission_rules_category_idx         on public.commission_rules (category_id) where category_id is not null;
create index commission_rules_service_category_idx on public.commission_rules (service_category_id) where service_category_id is not null;
create index vendor_orders_commission_rule_idx     on public.vendor_orders (commission_rule_id) where commission_rule_id is not null;
create index refunds_vendor_order_idx              on public.refunds (vendor_order_id) where vendor_order_id is not null;
create index service_bookings_vendor_service_idx   on public.service_bookings (vendor_service_id) where vendor_service_id is not null;
create index orders_delivery_address_idx           on public.orders (delivery_address_id) where delivery_address_id is not null;
create index pickup_dropoff_pickup_address_idx     on public.pickup_dropoff_requests (pickup_address_id) where pickup_address_id is not null;
create index pickup_dropoff_dropoff_address_idx    on public.pickup_dropoff_requests (dropoff_address_id) where dropoff_address_id is not null;
