-- 11: Step 4 support (additive only)
--  * cart_items.price_when_added: lets the cart tell the customer when a product's price changed after it was added.
--    It is informational; the cart always charges/shows the CURRENT product price.
--  * product_images unique path: the same stored file cannot be attached twice.
--  * adjust_product_stock(): atomic, race-safe stock change for backend order processing (later step). Never negative.

alter table public.cart_items add column price_when_added numeric(12,2) check (price_when_added is null or price_when_added >= 0);

create unique index product_images_product_path_key on public.product_images (product_id, storage_path);

create or replace function public.adjust_product_stock(p_product_id uuid, p_delta integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_qty integer;
begin
  update public.products
     set stock_quantity = stock_quantity + p_delta
   where id = p_product_id
     and stock_quantity + p_delta >= 0
  returning stock_quantity into new_qty;

  if not found then
    raise exception 'unknown product or insufficient stock' using errcode = '23514';
  end if;
  return new_qty;
end;
$$;

-- backend (service role) only: never callable by anon/authenticated API roles
revoke execute on function public.adjust_product_stock(uuid, integer) from public, anon, authenticated;
grant  execute on function public.adjust_product_stock(uuid, integer) to service_role;
