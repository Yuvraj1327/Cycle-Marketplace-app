-- 09: storage buckets + object policies (requires Supabase's `storage` schema)
-- Path convention: <bucket>/<owner_user_id>/...   (service-images: <customer_id>/<booking_id>/<file>)
-- Limits: 5 MB, jpeg/png/webp only. No anonymous uploads anywhere.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars',        'avatars',        false, 5242880, array['image/jpeg','image/png','image/webp']),
  ('shop-images',    'shop-images',    true,  5242880, array['image/jpeg','image/png','image/webp']),
  ('product-images', 'product-images', true,  5242880, array['image/jpeg','image/png','image/webp']),
  ('service-images', 'service-images', false, 5242880, array['image/jpeg','image/png','image/webp']),
  ('banners',        'banners',        true,  5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- may the signed-in vendor see images of this booking? (path segment 2 = booking id)
create or replace function public.vendor_owns_booking_path(object_name text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select split_part(object_name, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and exists (
       select 1 from public.service_bookings b
       where b.id = split_part(object_name, '/', 2)::uuid and b.vendor_id = public.current_vendor_id()
     );
$$;

-- avatars: private, owner only (+ admin read)
create policy avatars_owner_all on storage.objects for all to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_admin_read on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and public.is_admin());

-- shop-images: public read; vendor-role users write to their own folder (needed before approval, during registration)
create policy shop_images_public_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'shop-images');
create policy shop_images_vendor_write on storage.objects for all to authenticated
  using (bucket_id = 'shop-images' and (storage.foldername(name))[1] = (select auth.uid())::text and public.current_user_role() = 'vendor')
  with check (bucket_id = 'shop-images' and (storage.foldername(name))[1] = (select auth.uid())::text and public.current_user_role() = 'vendor');

-- product-images: public read; approved vendors write to their own folder
create policy product_images_public_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'product-images');
create policy product_images_vendor_write on storage.objects for all to authenticated
  using (bucket_id = 'product-images' and (storage.foldername(name))[1] = (select auth.uid())::text and public.is_approved_vendor())
  with check (bucket_id = 'product-images' and (storage.foldername(name))[1] = (select auth.uid())::text and public.is_approved_vendor());

-- service-images: private; customer owns <uid>/..., assigned vendor and admins may read
create policy service_images_customer_all on storage.objects for all to authenticated
  using (bucket_id = 'service-images' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'service-images' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy service_images_vendor_read on storage.objects for select to authenticated
  using (bucket_id = 'service-images' and public.vendor_owns_booking_path(name));
create policy service_images_admin_read on storage.objects for select to authenticated
  using (bucket_id = 'service-images' and public.is_admin());

-- banners: public read; admin write
create policy banners_public_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'banners');
create policy banners_admin_write on storage.objects for all to authenticated
  using (bucket_id = 'banners' and public.is_admin())
  with check (bucket_id = 'banners' and public.is_admin());
