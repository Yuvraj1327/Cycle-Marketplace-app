# Storage architecture (Supabase Storage)

No image is ever stored in PostgreSQL: the database holds only the **object path** (`products.product_images.storage_path`, `vendor_profiles.shop_image_paths`, `service_booking_images.storage_path`, `categories.image_path`, `banners.image_path`, …). Every bucket is limited to **5 MB** and **JPEG / PNG / WebP**; none allows anonymous writes. Buckets and policies are created by migration 09 (policies for `service-images` tightened in migration 20).

## Buckets

| Bucket | Public read | Who may write | Path convention | Used by |
|---|---|---|---|---|
| `product-images` | yes (catalogue photos) | an **approved** vendor, own folder only | `<vendor_user_id>/<product_id>/<random>.<ext>` | Vendor app uploads; Customer app + admin console display |
| `shop-images` | yes (shop front) | any **vendor-role** account (needed during registration, before approval), own folder only | `<vendor_user_id>/<random>.<ext>` | Vendor app uploads; admin vendor review + customer provider cards display |
| `service-images` | **no** (private) | **customer accounts only**, own folder only | `<customer_id>/<booking_id>/<random>.<ext>` | Customer app uploads cycle photos; shown through short-lived **signed URLs** |
| `banners` | yes | **admins only** | `banners/<uuid>.<ext>`, `categories/<uuid>.<ext>`, `service-categories/<uuid>.<ext>` | Admin console uploads; Customer app displays banners and category images |
| `avatars` | **no** (private) | the owner, own folder only (+ admin read) | `<user_id>/<name>.<ext>` | Bucket and policy exist; **no app uploads avatars yet** (the profile has an `avatar_path` field but no UI) |

Read access to private photos (`service-images`): the owning customer; the vendor of that booking (the policy checks the booking id in the path against `service_bookings.vendor_id`, so a vendor never sees photos of other vendors' bookings); admins. Everybody else, including anonymous users, sees nothing.

## Flow (the same in every app)

1. The app uploads the file **directly to Storage with the signed-in user's own session** (publishable key + user JWT). Storage RLS decides whether the write is allowed — there is no service-role key in any app.
2. The app then tells the **backend** the path (`POST /vendor/products/{id}/images`, `POST /service-bookings/{id}/images`, banner / category create or update). The backend refuses a path that is not under the caller's own folder, **checks that the object exists, and reads its real content type and size from Storage** (HEAD) — a client cannot register a file it did not upload, a non-image, or an oversized file.
3. Public images are displayed from the public URL built from the configured Supabase URL; private images are fetched through **signed URLs** created by the backend with the caller's token (`url` is `null` when the viewer may not read it). URLs are never stored.
4. Deleting or replacing: the backend removes the object when the record is removed (product / booking images); banner and category files are left in storage when a banner is deleted (documented in the admin UI).

## Validation layers

* Browser / app: type (JPEG, PNG, WebP) and 5 MB checks before upload (admin `utils/images.ts`, vendor `core/utils/images.dart`, customer booking flow).
* Storage: bucket `file_size_limit` and `allowed_mime_types` + RLS.
* Backend: path ownership, existence, MIME and size (`max_image_bytes`), maximum number of images per product (8) / booking (5).

## Verified how

* **Real PostgreSQL** (`test_storage_buckets_are_configured_and_every_policy_enforces_ownership`): bucket configuration (public flag, 5 MB, MIME list) and every policy — vendors write only their own folder; customers cannot write product / shop / banner images; only admins write banners; `service-images` writable only by customers and readable only by the owner, the booking's vendor and admins (a vendor sees only their own bookings' photos); avatars owner + admin only; anonymous reads only the public buckets. The policies run against the stubbed `storage.objects` table.
* **In-memory harness**: backend path / MIME / size checks (`test_product_images.py`, `test_service_bookings.py`) and the admin console's upload validation.
* **Not verified**: real Storage HTTP behaviour (upload API, signed-URL expiry, server-side MIME sniffing), CDN caching, image resizing, orphan-file cleanup of replaced banners.

## Open points

* Profile photos (`avatars`) have a bucket but no screen.
* Orphaned objects (a banner replaced or deleted) stay in the bucket until a cleanup job is added.
* Image resizing / thumbnails are not implemented (full-size files are served).
