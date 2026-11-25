# Database Schema (Step 2, extended in Step 4)

PostgreSQL on Supabase. Migrations live in `supabase/migrations/` (applied in filename order); reference seed in `supabase/seed/`.
All money columns are `numeric(12,2)`. All primary keys are UUIDs. Every table has RLS enabled.

## Roles and access model
| Role | How obtained | Access |
|---|---|---|
| `customer` | Default at signup | Own profile, addresses, cart, wishlist, orders, bookings, payments, notifications, tickets; public catalogue |
| `vendor` | Signup with `role=vendor` in metadata | Own vendor profile; (once **approved**) own products/services, own vendor orders and bookings |
| `admin` | **Never via signup.** Promoted by service role / SQL only (`update profiles set role='admin' ...`) | Read/manage all platform records |
| backend (service role) | `SUPABASE_SERVICE_ROLE_KEY`, server-side only | Bypasses RLS; performs checkout, payments, refunds, booking creation, notifications |

A signup that requests `role=admin` (or anything other than `vendor`) becomes `customer`. Role changes are rejected for every signed-in user (including admins) and are possible only with the service role / SQL. Vendor approval is stored in `vendor_profiles.verification_status` and can be changed only by an admin or the backend.

## Tables
### A. Users
| Table | Purpose / key columns |
|---|---|
| `profiles` | 1:1 with `auth.users` (created by trigger). `full_name, email, phone, role, status(active/inactive/restricted), avatar_path` |
| `user_addresses` | Many per user. `address_type(delivery/pickup/both)`, address fields, `is_default` (one default per user, partial unique index) |
| `vendor_profiles` | One per vendor user. `business_name, business_types[], address, contact, operating_hours jsonb, shop_image_paths[], service_area_postal_codes[], service_radius_km, pickup_available`, review fields `verification_status(pending/approved/rejected/suspended), reviewed_by, reviewed_at, review_notes, rejection_reason`. View `vendor_public_profiles` exposes only safe columns of approved vendors |

### B. Marketplace
| Table | Purpose / key columns |
|---|---|
| `categories` | `kind(new_cycle/used_cycle/spare_part/accessory)`, optional `parent_id` for sub-categories (tyres, brakes...), `is_active` |
| `products` | `vendor_id, category_id, product_type, name, brand, model, specifications jsonb, condition(new/used), price, stock_quantity, is_available, is_active, approval_status(pending/approved/rejected), is_featured, review fields`. Checks: new_cycle⇒new, used_cycle⇒used; `product_type` must equal category kind (trigger) |
| `product_images` | `storage_path`, `sort_order`, one `is_primary` per product |
| `carts` / `cart_items` | One cart per user; `unique(cart_id, product_id)`, quantity 1-100. No prices stored |
| `wishlists` / `wishlist_items` | One wishlist per user; unique product per list |

Public visibility = `is_active AND approval_status='approved' AND vendor approved & active`.

### C. Orders and payments
| Table | Purpose |
|---|---|
| `orders` | Customer checkout record: `order_number, customer_id, status(pending/confirmed/completed/cancelled), payment_method(online/cod), delivery_address jsonb (snapshot), subtotal, delivery_charge, discount_amount, total_amount, coupon snapshot`. CHECK `total = subtotal + delivery - discount` |
| `vendor_orders` | One per (order, vendor): fulfilment unit. `status(pending/accepted/rejected/preparing/ready_for_dispatch/out_for_delivery/delivered/cancelled)`, own money split, `commission_rule_id/commission_amount` snapshot |
| `order_items` | Snapshot of product name/brand/model/price/qty under a vendor_order; `line_total = unit_price*quantity` |
| `order_status_history` | Auto-written by triggers on orders / vendor_orders |
| `payments` | For an order **or** a service booking (exactly one). `method, provider, provider_order_id, provider_payment_id, amount, status(pending/successful/failed/cancelled)`. No gateway payloads are stored |
| `refunds` | `payment_id, vendor_order_id?, amount, status(requested/approved/processed/rejected/failed)` |

### D. Services
| Table | Purpose |
|---|---|
| `service_categories` | Seeded with the five quotation categories |
| `vendor_services` | A vendor's priced offering within a category, `estimated_duration_minutes` |
| `service_bookings` | Customer+vendor+service snapshot, cycle info, issue, preferred date + slot, `estimated_price` (immutable snapshot), `final_price` + `price_change_reason`, `status(pending/accepted/rejected/picked_up/in_service/ready_for_delivery/completed/cancelled)` |
| `service_booking_images` | Customer-uploaded photos (storage path) |
| `booking_status_history` | Auto-written by trigger |
| `pickup_dropoff_requests` | Separate lifecycle from the booking: address snapshots, scheduled times, `pickup_charge, dropoff_charge, pickup_status, delivery_status(pending/scheduled/completed/failed/cancelled)`, completion timestamps |

Booking status transitions are enforced in the database: pending→accepted/rejected/cancelled; accepted→picked_up/cancelled; picked_up→in_service→ready_for_delivery→completed. Admins may override. Vendor-order transitions are enforced similarly.

### E-G. Notifications, promotions, support
| Table | Purpose |
|---|---|
| `notifications` | `user_id, type, title, message, related_type/related_id, is_read, read_at`. Recipients may only change read state |
| `banners` | Image, action (none/product/category/service/url), schedule window, active flag |
| `coupons` | Code (case-insensitive unique), percentage/fixed, caps, min order, validity, usage limits, `used_count`. Admin-only table |
| `commission_rules` | Scope product/service; optional vendor/category target; percentage or fixed; priority; validity window |
| `platform_settings` | Key/value jsonb (e.g. `delivery_charge`, `pickup_charge`, `cod_enabled`); `is_public` controls anon visibility. **No values seeded** |
| `support_tickets` | Complaint / support request / dispute; optional order and booking link; status; admin assignment and notes. No chat |

## Relationships (summary)
`auth.users 1-1 profiles` · `profiles 1-N user_addresses` · `profiles 1-1 vendor_profiles` · `vendor_profiles 1-N products, vendor_services, vendor_orders, service_bookings` · `categories 1-N products` · `products 1-N product_images` · `profiles 1-1 carts 1-N cart_items` · `orders 1-N vendor_orders 1-N order_items` · `orders 1-N payments` · `payments 1-N refunds` · `service_bookings 1-N service_booking_images, booking_status_history, pickup_dropoff_requests` · `service_bookings 1-N payments` · `profiles 1-N notifications, support_tickets`.
Deletion: ownership children cascade; history-bearing parents (`profiles`, `vendor_profiles`, `orders`, `payments`) are `RESTRICT`; snapshot links (`order_items.product_id`, addresses) are `SET NULL`.

## Row Level Security
- **No policy = no access.** Public (anon) can read only: active categories, approved products + their images, approved vendors (via view), active services, active banners within window, public settings.
- Customers: SELECT-only on orders, order items, payments, refunds, bookings, histories. Writes that affect money or state (checkout, payment, refund, booking creation, cancellation) go through the **backend**.
- Vendors: update only fulfilment fields of their own `vendor_orders` / `service_bookings` / `pickup_dropoff_requests`; manage own products & services only when approved. Guard triggers make prices, totals, ownership, approval and featured flags immutable for them.
- Admins: full access via `is_admin()`.
- Recursion avoided with `SECURITY DEFINER` helpers (`is_admin, current_vendor_id, is_approved_vendor, vendor_is_approved, customer_owns_order, vendor_can_view_customer, ...`) with `search_path = ''`.
- Trigger functions have EXECUTE revoked from API roles.

## Storage (migration 09)
Path convention `<bucket>/<owner_uid>/...`; 5 MB; jpeg/png/webp; no anonymous writes.
| Bucket | Public read | Who writes | Notes |
|---|---|---|---|
| `avatars` | no | owner | admin can read |
| `shop-images` | yes | vendor-role user, own folder | allowed before approval (registration) |
| `product-images` | yes | **approved** vendor, own folder | URLs are unguessable UUID paths; unapproved images are technically fetchable if the URL is known |
| `service-images` | no | customer, own folder `<uid>/<booking_id>/` | assigned vendor + admin can read |
| `banners` | yes | admin only | |

## Design decisions
- Order schema is multi-vendor (`orders → vendor_orders`) regardless of the final cart rule.
- Snapshots (prices, names, addresses, service name/price) keep history stable.
- Enums for statuses; text+CHECK where values may evolve (`banners.action_type`, `notifications.related_type`).
- Order/booking/ticket numbers come from sequences.
- Account `status` (inactive/restricted) is enforced in policies only for registering as vendor and opening tickets; the backend must enforce it for checkout/booking.

## Unresolved business decisions (need client answers)
1. **Can customers list their own used cycles?** Schema currently allows only approved vendors (`products.vendor_id` → `vendor_profiles`).
2. **Multi-vendor cart?** Schema permits it; checkout behaviour not decided.
3. **Who physically delivers / picks up?** Not modelled (no rider). `pickup_dropoff_requests.notes` only; vendor updates status today.
4. **Vendor settlements:** automatic payout or records only? Only `commission_amount` snapshot exists; no settlement/payout table was created.
5. **Repair price changes after inspection:** `final_price` + `price_change_reason` exist and vendors can set them. Whether customer approval is required is undecided.
6. Payment gateway not chosen (`payments.provider` is free text). COD enablement and delivery/pickup charge amounts are undecided (settings keys unseeded). Whether charges are per order or per vendor order is open.
7. Whether editing an approved listing triggers re-approval.
8. Service time-slot capacity/availability management is not modelled beyond `operating_hours` and the booking's preferred slot.
9. Whether a rejected vendor may re-apply (currently the status is admin-controlled only).

## Step 4 additions (migration 11)
`cart_items.price_when_added` (informational price snapshot so the cart can flag price changes), unique index on `product_images (product_id, storage_path)`, and `adjust_product_stock(product_id, delta)` (atomic, never negative, `service_role` only). See `docs/marketplace-api.md`.

## Step 5 additions (migrations 12-14)
* **12** `payment_status` gains `processing`, `refunded`, `partially_refunded`; enum `settlement_status`.
* **13** `orders` (payment_status, idempotency_key, request_hash, payment_due_at, cancellation info); `vendor_orders` (vendor_name snapshot, released_at, cancellation info); `order_items` (stock_restored_at, commission snapshot); `payments` (refunded_amount, needs_review, recorded_by, one open attempt per order); `refunds` (order_id, idempotency_key, provider, failure_reason); tables `payment_events` (webhook idempotency), `vendor_settlements`, `audit_log`; vendor direct-update policy on `vendor_orders` removed.
* **14** transactional functions (service_role only) - see `docs/orders-payments.md`.

## Step 6 additions (migrations 15-16)
* **15** `vendor_services` (is_available, available_days, slot_minutes, max_bookings_per_slot); `service_bookings` (confirmed_* appointment, service_category_id / vendor_name / estimated_duration snapshots, duplicate-booking index); `pickup_dropoff_requests.customer_instructions`; `notifications.event_key` (+ unique per user); `service_categories.image_path`; new tables `service_charges` and `service_booking_notes`; vendor UPDATE policies on `service_bookings` / `pickup_dropoff_requests` dropped; booking guard/history triggers replaced (no-pickup flow, admin cancel, actor+note on backend writes).
* **16** transactional functions (service_role only) - see `docs/service-booking.md`.

## Step 9–10 additions (migrations 18-19)
* **18** read-only aggregates for the admin console (`admin_dashboard_summary`, `admin_entity_counts`; service_role only).
* **19** `announcements` (one row per admin broadcast; each recipient still gets an ordinary `notifications` row linked by the new `notifications.announcement_id`), `admin_send_announcement` (atomic fan-out to active accounts), `admin_announcement_stats`, `admin_report` (orders / sales / vendors / customers / services / payments, all service_role only), and a **fix** to `notifications.related_type`: the CHECK now also allows `vendor_application` (written by the Step 9 vendor decisions, which the original list rejected on a real database) and `vendor_service`. See `docs/admin-operations.md`.

## Step 11 additions (migration 20)
`device_tokens` (FCM tokens: RLS on, no policies, no privileges for anon/authenticated: backend-only); push outbox columns on `notifications` (`push_status`, `push_attempts`, `push_next_at`, `push_sent_at`, `push_error`; existing rows are `skipped`, new rows `pending`); functions `register_device_token`, `deactivate_device_token`, `claim_pending_pushes`, `finish_push`, `admin_push_status` and a new `admin_announcement_stats` (service_role only); the `notifications` guard trigger now also protects the push columns; triggers `notify_vendor_order_cancelled` and `notify_product_moderation`; the private `service-images` policy now allows writes by customer accounts only. See `docs/integration-audit.md`, `docs/push-notifications.md`, `docs/storage-architecture.md`.

## Step 12 review (no new migration)

Step 12 changed no schema. What was verified, on a throwaway **real PostgreSQL** cluster running migrations 01–20 in order:

* Every column, enum value and RPC argument that the backend code uses exists in these migrations (schema-conformance tests; they fail when a name is changed or misspelled).
* Primary / foreign keys, unique and check constraints, triggers (`updated_at`, notification guards, vendor / moderation notifications, push outbox) and SQL functions (stock, checkout, payments, refunds, settlements, dashboards, push claim / finish) behave as documented; concurrent push claims never return the same row twice.
* RLS: as the `authenticated` role, a user cannot update their own role or status, change or read another user's profile / addresses / notifications / orders, read another vendor's private records, or write into another user's storage folder; `device_tokens` is unreachable from clients. Security-definer functions are executable only by the roles that need them (trigger functions revoked in migration 20).
* Indexes: foreign keys on frequently joined columns are indexed (migration 10); 16 FK columns on audit / history tables are deliberately not indexed. With 60,000 products the filtered catalogue page took 21 ms and a text search 57 ms.
* Historical records: no migration drops a data table; orders, payments, refunds, bookings keep status columns, price snapshots and append-only history.

Still open from the list above ("Unresolved business decisions") — unchanged and waiting on the client: items 1–9. Defence-in-depth idea, not required: revoke the default table privileges of `anon` (RLS already blocks the rows).
Not verified: behaviour on a real Supabase project (extensions, Supabase-managed `auth` / `storage` schemas, PostgREST schema cache).
