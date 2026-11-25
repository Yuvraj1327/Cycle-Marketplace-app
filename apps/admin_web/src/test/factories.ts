/** Realistic backend payloads for the Step 10 screens (shapes mirror backend/app/schemas). */
const T = '2026-03-10T10:00:00Z'

export const product = (n: number, over: Record<string, unknown> = {}) => ({
  id: `p-${n}`, name: `Cycle ${n}`, brand: 'Hero', model: `M${n}`, price: 12000 + n, stock_quantity: 4, approval_status: 'pending', is_active: true, product_type: 'new_cycle', condition: 'new',
  primary_image_url: `https://img.test/p${n}.jpg`, description: 'A solid commuter.', specifications: { Frame: 'Alloy', Gears: 21 }, category_id: 'cat-1', category: { id: 'cat-1', name: 'New Cycles', slug: 'new-cycles', kind: 'new_cycle' },
  images: [{ id: `i-${n}`, url: `https://img.test/p${n}.jpg`, storage_path: `u/p${n}.jpg`, alt_text: null, sort_order: 0, is_primary: true }], is_available: true, in_stock: true, is_featured: false, moderation_status: 'pending',
  review_notes: null, reviewed_at: null, reviewed_by: null, created_at: T, updated_at: T, vendor: { id: 'v-1', business_name: 'Alpha Cycles' },
  vendor_admin: { id: 'v-1', business_name: 'Alpha Cycles', verification_status: 'approved', city: 'Pune', state: 'MH', contact_phone: '+919800000001', contact_email: 'alpha@shop.test' }, ...over,
})

export const category = (n: number, over: Record<string, unknown> = {}) => ({
  id: `cat-${n}`, parent_id: null, kind: 'new_cycle', name: `Category ${n}`, slug: `category-${n}`, description: null, image_url: null, image_path: null, sort_order: n, is_active: true, product_count: 0, created_at: T, updated_at: T, ...over,
})

export const serviceCategory = (n: number, over: Record<string, unknown> = {}) => ({
  id: `sc-${n}`, name: `Service ${n}`, slug: `service-${n}`, description: null, image_url: null, image_path: null, sort_order: n, is_active: true, service_count: 0, booking_count: 0, created_at: T, updated_at: T, ...over,
})

export const banner = (n: number, over: Record<string, unknown> = {}) => ({
  id: `b-${n}`, title: `Banner ${n}`, subtitle: 'Limited time', image_url: `https://img.test/b${n}.jpg`, image_path: `banners/b${n}.jpg`, action_type: 'none', action_value: null, sort_order: n, is_active: true, starts_at: null, ends_at: null, created_at: `2026-03-0${n}T10:00:00Z`, updated_at: T, ...over,
})

export const item = (n: number, over: Record<string, unknown> = {}) => ({ id: `it-${n}`, product_id: `p-${n}`, product_name: `Cycle ${n}`, product_brand: 'Hero', product_model: `M${n}`, product_condition: 'new', image_url: null, unit_price: 12000, quantity: 2, line_total: 24000, ...over })

export const vendorOrder = (n: number, over: Record<string, unknown> = {}) => ({
  id: `vo-${n}`, vendor_order_number: `VO-000${n}`, vendor_id: `v-${n}`, vendor_name: `Vendor ${n}`, status: 'pending', subtotal: 24000, delivery_charge: 0, discount_amount: 0, total_amount: 24000, accepted_at: null, delivered_at: null,
  rejection_reason: null, cancellation_reason: null, items: [item(n)], ...over,
})

export const order = (n: number, over: Record<string, unknown> = {}) => ({
  id: `o-${n}`, order_number: `ORD-000${n}`, status: 'confirmed', payment_method: 'cod', payment_status: 'pending', total_amount: 24050, subtotal: 24000, delivery_charge: 50, discount_amount: 0, coupon_code: null,
  customer_note: null, delivery_address: { recipient_name: 'Asha', address_line1: '1 MG Rd', city: 'Pune', state: 'MH', postal_code: '411001', phone: '+919800000001' }, payment_due_at: null, cancelled_at: null, cancelled_reason: null, cancelled_by_role: null,
  can_cancel: true, item_count: 2, vendor_count: 1, created_at: T, customer: { id: 'c-1', full_name: 'Asha Rao', email: 'asha@example.com', phone: '+919800000001' }, vendor_orders: [vendorOrder(n)], payments: [], refunds: [], ...over,
})

export const fulfilment = (n: number, over: Record<string, unknown> = {}) => ({
  id: `vo-${n}`, vendor_order_number: `VO-000${n}`, order_id: `o-${n}`, order_number: `ORD-000${n}`, vendor_id: `v-${n}`, vendor_name: `Vendor ${n}`, customer_id: 'c-1', customer_name: 'Asha Rao', status: 'accepted', order_status: 'confirmed',
  payment_method: 'cod', payment_status: 'pending', delivery_city: 'Pune', delivery_postal_code: '411001', item_count: 2, subtotal: 24000, total_amount: 24000, commission_amount: null, accepted_at: T, delivered_at: null, created_at: T, ...over,
})

export const service = (n: number, over: Record<string, unknown> = {}) => ({
  id: `s-${n}`, service_category_id: 'sc-1', category: { id: 'sc-1', name: 'General Servicing', slug: 'general-servicing' }, name: `Full service ${n}`, description: 'Complete check and tune-up.', price: 499, estimated_duration_minutes: 120, is_active: true, is_available: true,
  available_days: ['mon', 'tue'], slot_minutes: 60, max_bookings_per_slot: 1, created_at: T, updated_at: T, vendor_id: 'v-1', vendor_name: 'Alpha Cycles', vendor_status: 'approved', ...over,
})

export const booking = (n: number, over: Record<string, unknown> = {}) => ({
  id: `bk-${n}`, booking_number: `BKG-000${n}`, status: 'pending', service_name: 'Full service', service_category: 'General Servicing', vendor_name: 'Alpha Cycles', current_price: 499, created_at: T, customer_id: 'c-1', vendor_id: 'v-1',
  customer: { full_name: 'Asha Rao', phone: '+919800000001' }, preferred: { date: '2026-03-20', slot_start: '10:00:00' }, confirmed: { date: null, slot_start: null }, needs_pickup_dropoff: true, pickup_stage: 'requested', delivery_stage: null, issue_description: 'Brakes squeal', ...over,
})

export const pickupDetail = (over: Record<string, unknown> = {}) => ({
  id: 'pk-1', pickup_address: { address_line1: '1 MG Rd', city: 'Pune', postal_code: '411001' }, dropoff_address: { address_line1: '1 MG Rd', city: 'Pune', postal_code: '411001' }, pickup_status: 'pending', pickup_stage: 'requested', delivery_status: 'pending', delivery_stage: 'requested',
  scheduled_pickup_at: null, scheduled_delivery_at: null, picked_up_at: null, delivered_at: null, pickup_charge: 50, dropoff_charge: 50, customer_instructions: 'Call at gate', notes: null, ...over,
})

export const bookingDetail = (n: number, over: Record<string, unknown> = {}) => ({
  ...booking(n), service_id: 's-1', service_category: { id: 'sc-1', name: 'General Servicing' }, vendor: null, vendor_admin: { id: 'v-1', business_name: 'Alpha Cycles', city: 'Pune', state: 'MH', contact_phone: '+919811100000', verification_status: 'approved' },
  cycle: { brand: 'Hero', model: 'Sprint', details: 'Blue, 26 inch' }, estimated_duration_minutes: 120, accepted_at: null, completed_at: null, completion_notes: null, rejection_reason: null, cancellation_reason: null, can_cancel: true,
  preferred: { date: '2026-03-20', slot_start: '10:00:00', slot_end: '11:00:00' }, confirmed: { date: null, slot_start: null, slot_end: null },
  pricing: { estimated_price: 499, additional_charges_total: 150, current_price: 649, pickup_charge: 50, dropoff_charge: 50, total_estimated: 599, total_current: 749, logistics_charges_configured: true },
  pickup: pickupDetail(), charges: [{ id: 'ch-1', amount: 150, reason: 'Replaced brake pads', recorded_role: 'vendor', created_at: T }], notes: [{ id: 'n-1', author_role: 'vendor', note: 'Brake pads worn', created_at: T }],
  images: [{ id: 'im-1', storage_path: 'c/1.jpg', url: 'https://signed.test/1.jpg' }], ...over,
})

export const pickupItem = (n: number, over: Record<string, unknown> = {}) => ({
  id: `pk-${n}`, booking_id: `bk-${n}`, booking_number: `BKG-000${n}`, booking_status: 'accepted', service_name: 'Full service', vendor_name: 'Alpha Cycles', customer: { full_name: 'Asha Rao', phone: '+919800000001' }, pickup: pickupDetail({ id: `pk-${n}` }),
  preferred: { date: '2026-03-20', slot_start: '10:00:00' }, ...over,
})

export const payment = (n: number, over: Record<string, unknown> = {}) => ({
  id: `pay-${n}`, order_id: `o-${n}`, method: 'online', provider: 'testpay', provider_order_id: `po_${n}`, provider_payment_id: `pp_${n}`, status: 'successful', amount: 1000, amount_due: 0, refunded_amount: 0, currency: 'INR', paid_at: T, failure_reason: null,
  created_at: T, customer_id: 'c-1', needs_review: false, review_reason: null, recorded_by: null, order_number: `ORD-000${n}`, customer_name: 'Asha Rao', ...over,
})

export const refund = (n: number, over: Record<string, unknown> = {}) => ({
  id: `rf-${n}000000`, payment_id: `pay-${n}`, order_id: `o-${n}`, order_number: `ORD-000${n}`, vendor_order_id: null, amount: 300, reason: 'Damaged item', status: 'requested', provider: null, provider_refund_id: null, failure_reason: null,
  requested_by: 'u-1', processed_by: null, processed_at: null, created_at: T, ...over,
})

export const rule = (n: number, over: Record<string, unknown> = {}) => ({
  id: `r-${n}`, name: `Rule ${n}`, applies_to: 'product', vendor_id: null, category_id: null, service_category_id: null, commission_type: 'percentage', commission_value: 10, priority: 0, is_active: true, effective_from: T, effective_until: null, created_at: T,
  vendor_name: null, category_name: null, service_category_name: null, scope: 'global', state: 'active', ...over,
})

export const settlement = (n: number, over: Record<string, unknown> = {}) => ({
  id: `st-${n}0000000`, vendor_id: `v-${n}`, vendor_name: `Vendor ${n}`, vendor_order_id: `vo-${n}`, order_number: `VO-000${n}`, gross_amount: 24000, commission_amount: 2400, deductions_amount: 0, net_amount: 21600, status: 'ready', payout_reference: null, settled_at: null, created_at: T, notes: null, ...over,
})

export const coupon = (n: number, over: Record<string, unknown> = {}) => ({
  id: `cp-${n}`, code: `SAVE${n}0`, description: null, discount_type: 'percentage', discount_value: 10, max_discount_amount: 200, min_order_amount: 500, applies_to: 'all', valid_from: T, valid_until: null, usage_limit: 100, per_user_limit: 1, used_count: 0,
  is_active: true, state: 'active', created_at: T, updated_at: T, ...over,
})

export const announcement = (n: number, over: Record<string, unknown> = {}) => ({
  id: `an-${n}`, title: `Notice ${n}`, message: 'Something important for everyone.', type: 'announcement', audience: 'customers', recipient_count: 10, delivered: 10, read: 4, push_sent: 7, push_failed: 0, push_pending: 0, created_by: 'u-1', created_by_name: 'Root Admin', created_at: T, channel: 'in_app', ...over,
})

export const notificationRecord = (n: number, over: Record<string, unknown> = {}) => ({
  id: `nt-${n}`, user_id: 'c-1', recipient_name: 'Asha Rao', recipient_role: 'customer', type: 'order', title: 'Order confirmed', message: 'Your order ORD-0001 is confirmed.', related_type: 'order', related_id: 'o-1', is_read: false, announcement_id: null, created_at: T, channel: 'in_app', push_status: 'sent', push_error: null, ...over,
})

export const setting = (key: string, value: unknown, over: Record<string, unknown> = {}) => ({ key, value, configured: value !== undefined && value !== null, description: `About ${key}`, default_behaviour: 'the safe default', ...over })

export const timeline = () => [
  { at: '2026-03-10T10:00:00Z', scope: 'order', vendor_order_id: null, vendor_name: null, from_status: null, to_status: 'confirmed', note: null, changed_by_id: 'c-1', changed_by_name: 'Asha Rao', changed_by_role: 'customer' },
  { at: '2026-03-10T11:00:00Z', scope: 'vendor_order', vendor_order_id: 'vo-1', vendor_name: 'Vendor 1', from_status: 'pending', to_status: 'accepted', note: null, changed_by_id: 'vu-1', changed_by_name: 'Vendor One', changed_by_role: 'vendor' },
]

export const audit = (over: Record<string, unknown> = {}) => ({ id: 'au-1', actor_id: 'u-1', actor_name: 'Root Admin', actor_role: 'admin', action: 'product_approval_changed', entity_type: 'product', entity_id: 'p-1', details: { from: 'pending', to: 'approved' }, created_at: T, ...over })
