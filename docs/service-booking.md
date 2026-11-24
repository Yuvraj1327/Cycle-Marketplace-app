# Cycle servicing, repair bookings and doorstep pickup/drop-off (Step 6)

Interactive docs: `/docs`. Errors: `{"error": {"code", "message", "details?"}}`. Money = JSON number (2 decimals), computed with `Decimal`.

## Where the logic lives
| Concern | Where |
|---|---|
| Who may do what, slot/hours/area/address validation, settings, views | FastAPI services |
| Anything that must be atomic or audited: booking creation (price read from the DB), accept + capacity, status machine, charges, notes, logistics, notifications | PL/pgSQL functions (migration 16), `service_role` only |
| Reads | the caller's own JWT (RLS), plus explicit owner filters in the services |

Functions: `create_service_booking`, `accept_service_booking`, `reschedule_service_booking`, `transition_service_booking`, `add_service_charge`, `add_service_note`, `set_service_logistics`, `cm_notify_once`. API roles cannot execute them. Migration 15 also **drops** the Step 2 policies that let vendors update `service_bookings` / `pickup_dropoff_requests` directly through Supabase (that path could rewrite `final_price`, skip history and notifications).

## Categories and services
* Platform categories (seeded: General Servicing, Puncture Repair, Brake Repair, Gear Adjustment, Parts Replacement) are managed **only by admins** (`/admin/service-categories`; slug auto-generated; delete refused while a vendor service or booking uses the category - deactivate instead). Vendors choose from active categories and may offer any subset.
* Vendor services: name, description, price, `estimated_duration_minutes`, `is_active` (visible at all), `is_available` (pause bookings), `available_days`, `slot_minutes` (15-240, multiples of 5), `max_bookings_per_slot` (1-20). Only **approved** vendors can manage them. A service that ever received a booking is **deactivated, never deleted**; bookings snapshot service name, price, duration, category and provider name, so history never changes.
* Public browse shows only active + available services of approved providers; the provider summary has no street address, phone or e-mail.

## Availability and scheduling (no staff calendars)
Slots are generated from the vendor's own `operating_hours` (Step 3) for that weekday, in `BUSINESS_TIMEZONE` (default `Asia/Kolkata`), at the service's `slot_minutes`. A slot is bookable if: the service is offered that weekday, the date is within `services.max_advance_days` (default 60) and respects `services.min_notice_hours` (default 0), and the number of **accepted** bookings of that service in that slot is below `max_bookings_per_slot`. Pending bookings do **not** hold a slot. `reason` codes explain an empty list (`vendor_hours_not_configured` is explicit: with no hours there is nothing to validate against, so the service cannot be booked).
* **Preferred vs confirmed:** the customer's chosen slot is stored as `preferred_*` and never changes. The provider confirms the appointment when accepting (default: the preferred slot, or another valid slot) and can reschedule while `accepted`; that is `confirmed_*`.
* Capacity is enforced inside the database with the vendor row locked, so simultaneous accepts cannot overbook (verified: 8 parallel accepts into a capacity-2 slot -> exactly 2 succeed).
* A customer cannot hold two open bookings for the same service and slot (unique index); cancelling frees it.

## Booking lifecycle
`pending -> accepted -> [picked_up] -> in_service -> ready_for_delivery -> completed`, plus `rejected` (from pending, reason required) and `cancelled`.
* With doorstep pickup: `accepted -> picked_up -> in_service`. **Without** it: `accepted -> in_service` directly (the customer brings the cycle) - no pointless pickup status.
* Customer cancels while `pending`/`accepted`; vendor cancels while `accepted` (reason required); admin can cancel any open booking, including mid-repair. Cancelling releases the confirmed slot and cancels pickup/drop-off steps.
* Every change is written to `booking_status_history` with actor and note; timestamps `accepted_at`, `completed_at` are stamped; the SQL trigger enforces the same machine.

## Additional repair charges (never silent)
`estimated_price` is a snapshot of the vendor service price at booking time and is **immutable**. Extra work is appended to `service_charges` (amount, reason, who, when; a negative amount records a correction), allowed while accepted..ready_for_delivery. `current_price = estimate + sum(charges)` (stored as `final_price`); the customer is notified; history is append-only. **Nothing is charged or collected** - no payment gateway is involved for bookings. Whether customers must approve extra charges before work continues is **undecided** (client clarification).

## Notes
Vendors (and admins) append `service_booking_notes`; customers see them in their booking.

## Pickup and drop-off (logistics kept apart from repair status)
`pickup_dropoff_requests` is created with the booking when doorstep pickup/drop-off is requested (one flag covers both directions). Customer chooses saved addresses (pickup: type pickup/both; drop-off: delivery/both, default = pickup address); the provider must offer pickup, and if it lists service-area postal codes both addresses must be inside. Address snapshots, instructions and charges are stored on the request.
* **Stages** (API names -> database): requested = `pending`, scheduled, picked_up / delivered = `completed`, failed, cancelled. Two independent fields: `pickup_status` and `delivery_status`.
* **Coordination** (vendor `PATCH /vendor/pickup-requests/{id}`, admin `PATCH /admin/pickup-requests/{id}/status`): schedule/reschedule, mark an attempt `failed`, `cancelled`, add notes.
* **Completion has a single source of truth - the booking status:** `picked_up` records pickup completion, `completed` records delivery completion. This prevents contradictory states; coordination endpoints refuse `completed`.
* No rider app, no GPS, no live map.
* **Charges** come from platform settings `services.pickup_charge` / `services.dropoff_charge` (admin `PUT /admin/settings/{key}`) and are snapshotted on the request. **If unset they are recorded as 0 and the booking says `logistics_charges_configured: false`** - no amount is ever invented.

## Images
Private bucket `service-images` (Step 2). Flow: create the booking -> upload to `<customer_id>/<booking_id>/<file>.jpg|png|webp` with the customer's own Supabase session (5 MB, mime-restricted by the bucket) -> `POST /service-bookings/{id}/images` registers the path (path pattern, existence via Storage, type/size, max 5, only while `pending`). No binaries touch FastAPI or PostgreSQL. Detail views return **short-lived signed URLs created as the viewer**, so storage RLS decides: the customer, the assigned vendor and admins can open them; other vendors/customers cannot.

## Notifications (rows only; no push)
Written in the same transaction as the event, one per (user, `event_key`) so replays cannot duplicate: customer - booking received, accepted, rejected, pickup completed, repair started, ready for delivery, completed, cancelled, charge updated, appointment rescheduled, pickup/delivery scheduled/failed; vendor - new booking, cancellation; admins - new service request, cancellation. FCM/push delivery is a later step.

## Complaints and disputes
`/support-tickets` (customer: create, list, get; may link one of their own bookings/orders) and `/admin/support-tickets` (list, filter, triage: status, assignment, internal notes, resolution). No chat.

## Endpoints
Public: `GET /service-categories`, `/service-categories/{id}`, `/services`, `/services/{id}`, `/services/{id}/availability?date=`, `/vendors/{id}/services`.
Customer: `POST/GET /service-bookings`, `GET /service-bookings/{id}`, `.../tracking`, `POST .../cancel`, `POST .../images`, `DELETE .../images/{image_id}`, `POST/GET /support-tickets`, `GET /support-tickets/{id}`.
Vendor (approved): `POST/GET /vendor/services`, `GET/PUT/PATCH/DELETE /vendor/services/{id}`; `GET /vendor/service-bookings`, `GET .../{id}`, `POST .../accept`, `POST .../reject`, `PATCH .../status`, `PUT .../schedule`, `POST .../charges`, `POST .../notes`; `GET /vendor/pickup-requests`, `GET/PATCH /vendor/pickup-requests/{id}`.
Admin: `GET/POST /admin/service-categories`, `PUT/DELETE .../{id}`; `GET /admin/services`, `.../{id}`; `GET /admin/service-bookings`, `.../{id}`, `PATCH .../{id}/status`; `GET /admin/pickup-requests`, `.../{id}`, `PATCH .../{id}/status`; `GET /admin/support-tickets`, `GET/PATCH .../{id}`.

## Settings used
`services.pickup_charge`, `services.dropoff_charge`, `services.min_notice_hours`, `services.max_advance_days` (see `GET /admin/settings`).

## Open client decisions
Customer approval of additional charges; payment for services (none implemented); whether one flag for pickup+drop-off is enough or customers need pickup-only/drop-off-only; cancellation rules after pickup; whether vendors without configured opening hours should be bookable; who physically performs pickup/return (vendor staff assumed, no rider app); pickup/drop-off charge amounts; staff-level scheduling (deliberately not built).
