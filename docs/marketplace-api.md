# Marketplace API (Step 4)

Interactive docs: `/docs`. All errors: `{"error": {"code", "message", "details?"}}`. Money is a JSON number with 2 decimals. Lists are paginated: `?page=1&limit=20` (limit 1-100) -> `{items, total, page, limit, pages}`.

## Access model
| Who | Data client | Notes |
|---|---|---|
| Public (anonymous) | anon key | RLS shows only approved + active listings of approved vendors, active categories/banners |
| Customer / vendor / admin | the caller's own JWT | RLS + guard triggers from Step 2 still apply |
| Service role | `SUPABASE_SERVICE_ROLE_KEY` (server only) | used in exactly two places: reading `platform_settings` + moving a listing to `approved`/`pending` per policy (`VendorProductService`), and stock adjustment (`InventoryService`, no HTTP route) |

## Endpoints
**Public:** `GET /categories`, `GET /categories/{id}`, `GET /products`, `GET /products/featured`, `GET /products/{id}`, `GET /banners`
**Vendor (approved vendors only):** `POST/GET /vendor/products`, `GET/PUT/PATCH/DELETE /vendor/products/{id}`, images: `GET/POST /vendor/products/{id}/images`, `PUT .../images/order`, `PATCH/DELETE .../images/{image_id}`
**Customer:** `GET /cart`, `POST /cart/items`, `PUT/DELETE /cart/items/{id}`, `DELETE /cart/clear`, `GET /wishlist`, `POST /wishlist/items`, `DELETE /wishlist/items/{id}`
**Admin:** `GET/POST /admin/categories`, `PUT/DELETE /admin/categories/{id}`, `GET /admin/products`, `GET /admin/products/{id}`, `PATCH /admin/products/{id}/approval|status|featured`, `GET/POST /admin/banners`, `PUT/DELETE /admin/banners/{id}`

## Search (`GET /products`)
`q` (name, brand, model, description, category name), `category_id` (includes sub-categories), `product_type`, `min_price`, `max_price`, `brand`, `condition`, `in_stock`, `sort_by` = `relevance` (featured first, then newest) | `price_low_to_high` | `price_high_to_low` | `newest`. Filters AND together. User text is reduced to a safe alphabet and LIKE wildcards are escaped before it reaches PostgREST; a search that reduces to nothing returns no results. Implemented with `ILIKE` (fine for catalogue-scale data; add `pg_trgm` indexes if the catalogue grows to tens of thousands of rows).

## Moderation
DB enum `listing_status` = pending | approved | rejected. The API's fourth state **inactive** is `is_active = false` (`moderation_status` in responses: inactive > rejected/pending/approved).
* New listings are `pending` unless platform setting `marketplace.require_listing_approval` is the JSON boolean `false` (unset/malformed = moderation ON). Set it with `insert into platform_settings(key,value) values ('marketplace.require_listing_approval','false')` (an admin settings API comes in a later step).
* Vendors can never send/modify approval or featured fields (422, and DB triggers block them as well).
* Editing a **rejected** listing resubmits it (back to the moderation policy).
* Editing an **approved** listing does not reset approval (open client decision).
* Admin deactivation via `/status` can be reversed by the vendor; to enforce a takedown, reject the listing.

## Inventory
`stock_quantity` is set absolutely by the vendor (>= 0). Carts never reserve or deduct stock. For checkout (later) use `InventoryService.adjust(product_id, delta)` -> SQL function `adjust_product_stock` (atomic, can't go negative, executable by `service_role` only).

## Product images (direct upload; files never pass through FastAPI/PostgreSQL)
1. Vendor app uploads to Storage bucket `product-images` with the **vendor's own Supabase session** at `<vendor_user_id>/<product_id>/<file>.jpg|jpeg|png|webp` (<= 5 MB). Storage RLS (migration 09) permits this only for approved vendors in their own folder.
2. Vendor app calls `POST /vendor/products/{id}/images {"storage_path": "..."}`. The backend checks ownership of the product, the exact path pattern, that the object exists, its content-type and size, max 8 images, and no duplicates. First image becomes primary.
3. Deleting an image removes the file as the vendor (Storage RLS applies) and the row.
Category images and banner images use the public `banners` bucket (admin-writable), referenced by `image_path`.

## Cart & wishlist
* One cart / wishlist per customer, created on first use. Items carry a `status`: ok | not_listed | unavailable | out_of_stock | insufficient_stock.
* Cart subtotal = sum of **current** prices of `ok` items only; no delivery/service charges/discounts. `price_when_added` (new column) powers `price_changed`/`previous_price`; saving a quantity acknowledges the new price.
* A cart may contain several vendors (`vendors[]` grouping and `multi_vendor` are informational) - **final multi-vendor checkout behaviour awaits client confirmation**.
* Wishlist: duplicates prevented (re-adding returns the existing entry, 200); out-of-stock products may be saved; unlisted ones may not.

## Safe deletion
Vendor `DELETE` hard-deletes only never-ordered products; otherwise it deactivates (order history keeps its snapshot). Admin category deletion is refused (409) while any product or sub-category uses it - deactivate instead (no re-assignment tool yet).

## Database changes (migration `20260101000011_marketplace_support.sql`, additive)
`cart_items.price_when_added`; unique `(product_id, storage_path)` on `product_images`; function `adjust_product_stock(uuid, int)`.
