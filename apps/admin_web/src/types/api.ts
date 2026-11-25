/** Types mirror the backend's OpenAPI schemas (backend/app/schemas/*). Only fields the admin console uses are declared. */
export interface Page<T> {
  items: T[]
  total: number
  page: number
  limit: number
  pages: number
}

export type AccountStatus = 'active' | 'inactive' | 'restricted'
export type VerificationStatus = 'pending' | 'approved' | 'rejected' | 'suspended'
export type BusinessType = 'bicycle_shop' | 'used_cycle_seller' | 'spare_parts_seller' | 'service_provider'
export type SortBy = 'newest' | 'oldest' | 'name'

export interface SessionInfo {
  session_id: string | null
  assurance_level: string | null
  token_expires_at: string
}

export interface Profile {
  id: string
  full_name: string
  email: string | null
  phone: string | null
  role: string
  status: string
  avatar_path: string | null
  created_at: string
  updated_at: string
}

export interface Me {
  id: string
  email: string | null
  phone: string | null
  role: string
  status: string
  vendor_verification_status: string | null
  session: SessionInfo
  profile: Profile
}

export interface AuditEntry {
  at: string
  action: string
  actor_id: string | null
  details: Record<string, unknown>
}

export interface CustomerListItem {
  id: string
  full_name: string | null
  email: string | null
  phone: string | null
  status: AccountStatus
  created_at: string
  order_count: number | null
  booking_count: number | null
}

export interface Address {
  id: string
  label?: string | null
  recipient_name?: string
  phone?: string
  address_line1?: string
  address_line2?: string | null
  landmark?: string | null
  city?: string
  state?: string
  postal_code?: string
  address_type?: string
  is_default?: boolean
}

export interface CustomerDetail extends CustomerListItem {
  updated_at: string
  addresses: Address[]
  activity: AuditEntry[]
}

export interface VendorListItem {
  id: string
  user_id: string
  business_name: string
  owner_name: string | null
  owner_email: string | null
  contact_phone: string
  contact_email: string | null
  business_types: BusinessType[]
  city: string
  state: string
  verification_status: VerificationStatus
  account_status: AccountStatus | null
  created_at: string
  product_count: number | null
  order_count: number | null
  booking_count: number | null
}

export interface DayHours {
  closed?: boolean
  open?: string | null
  close?: string | null
}

export interface VendorDetail extends VendorListItem {
  owner_phone: string | null
  description: string | null
  address_line1: string
  address_line2: string | null
  postal_code: string
  operating_hours: Record<string, DayHours>
  shop_image_paths: string[]
  shop_image_urls: string[]
  service_area_postal_codes: string[]
  service_radius_km: number | null
  pickup_available: boolean
  rejection_reason: string | null
  review_notes: string | null
  reviewed_by: string | null
  reviewed_at: string | null
  updated_at: string
  activity: AuditEntry[]
}

export interface DayCount {
  day: string
  count: number
}
export interface DayOrders extends DayCount {
  value: number
}

export interface Dashboard {
  period: { from: string; to: string }
  customers: { total: number; by_status: Record<string, number>; new_in_period: number }
  vendors: { total: number; by_verification: Record<string, number>; by_account_status: Record<string, number>; new_in_period: number }
  orders: { total: number; by_status: Record<string, number>; value_completed: number; value_confirmed: number }
  bookings: { total: number; by_status: Record<string, number> }
  series: { orders: DayOrders[]; bookings: DayCount[]; customers: DayCount[]; vendors: DayCount[] }
}

export interface RevenueSummary {
  period_from: string
  period_to: string
  collected: number
  refunded: number
  net_collected: number
  commission_earned: number
  cod_outstanding: number
  orders_placed: number
  orders_completed: number
}

export interface AdminOrderItem {
  id: string
  order_number: string
  status: string
  payment_method: string
  payment_status: string
  total_amount: number
  item_count: number
  vendor_count: number
  created_at: string
  customer: { id: string; full_name: string | null; email: string | null; phone: string | null } | null
  vendor_orders: { id: string; vendor_id: string; vendor_name: string | null; status: string; total_amount: number }[]
}

export interface AdminBookingItem {
  id: string
  booking_number: string
  status: string
  service_name: string
  vendor_name: string | null
  current_price: number
  created_at: string
  customer_id: string
  vendor_id: string
  customer: { full_name: string | null; phone: string | null } | null
  preferred: { date: string | null; slot_start: string | null }
}

export interface AdminProductItem {
  id: string
  name: string
  brand: string | null
  model: string | null
  price: number
  stock_quantity: number
  approval_status: string
  is_active: boolean
  product_type: string
  primary_image_url: string | null
}

// ------------------------------------------------------------------ Step 10: marketplace
export type ProductType = 'new_cycle' | 'used_cycle' | 'spare_part' | 'accessory'
export type ApprovalStatus = 'pending' | 'approved' | 'rejected'
export type ModerationStatus = 'pending' | 'approved' | 'rejected' | 'inactive'

export interface ProductImage { id: string; url: string; storage_path: string; alt_text: string | null; sort_order: number; is_primary: boolean }
export interface CategoryRef { id: string; name: string; slug: string; kind: ProductType }
export interface AdminProduct extends AdminProductItem {
  description: string | null
  specifications: Record<string, unknown>
  condition: string
  category_id: string
  category: CategoryRef | null
  images: ProductImage[]
  is_available: boolean
  in_stock: boolean
  is_featured: boolean
  moderation_status: ModerationStatus
  review_notes: string | null
  reviewed_at: string | null
  reviewed_by: string | null
  created_at: string
  updated_at: string
  vendor: { id: string; business_name: string; city?: string | null; state?: string | null } | null
  vendor_admin: { id: string; business_name: string; verification_status: string | null; city: string | null; state: string | null; contact_phone: string | null; contact_email: string | null } | null
}

export interface Category {
  id: string
  parent_id: string | null
  kind: ProductType
  name: string
  slug: string
  description: string | null
  image_url: string | null
  image_path: string | null
  sort_order: number
  is_active: boolean
  product_count: number | null
  created_at: string
  updated_at: string
}
export interface CategoryInput { name: string; kind?: ProductType; description?: string | null; image_path?: string | null; sort_order?: number; is_active?: boolean }

export interface Banner {
  id: string
  title: string
  subtitle: string | null
  image_url: string
  image_path: string
  action_type: 'none' | 'product' | 'category' | 'service' | 'url'
  action_value: string | null
  sort_order: number
  is_active: boolean
  starts_at: string | null
  ends_at: string | null
  created_at: string
  updated_at: string
}
export interface BannerInput {
  title?: string
  subtitle?: string | null
  image_path?: string
  action_type?: Banner['action_type']
  action_value?: string | null
  sort_order?: number
  is_active?: boolean
  starts_at?: string | null
  ends_at?: string | null
}

// ------------------------------------------------------------------ orders
export interface OrderItem { id: string; product_id: string | null; product_name: string; product_brand: string | null; product_model: string | null; product_condition: string | null; image_url: string | null; unit_price: number; quantity: number; line_total: number }
export interface VendorOrder {
  id: string
  vendor_order_number: string
  vendor_id: string
  vendor_name: string | null
  status: string
  subtotal: number
  delivery_charge: number
  discount_amount: number
  total_amount: number
  accepted_at: string | null
  delivered_at: string | null
  rejection_reason: string | null
  cancellation_reason: string | null
  items: OrderItem[]
}
export interface PaymentRecord {
  id: string
  order_id: string | null
  method: string
  provider: string | null
  provider_order_id: string | null
  provider_payment_id: string | null
  status: string
  amount: number
  amount_due: number
  refunded_amount: number
  currency: string
  paid_at: string | null
  failure_reason: string | null
  created_at: string
  customer_id: string
  needs_review: boolean
  review_reason: string | null
  recorded_by: string | null
  order_number: string | null
  customer_name: string | null
}
export interface RefundRecord {
  id: string
  payment_id: string
  order_id: string | null
  order_number: string | null
  vendor_order_id: string | null
  amount: number
  reason: string | null
  status: 'requested' | 'approved' | 'processed' | 'rejected' | 'failed'
  provider: string | null
  provider_refund_id: string | null
  failure_reason: string | null
  requested_by: string | null
  processed_by: string | null
  processed_at: string | null
  created_at: string
}
export interface AdminOrder extends AdminOrderItem {
  payment_status: string
  subtotal: number
  delivery_charge: number
  discount_amount: number
  coupon_code: string | null
  customer_note: string | null
  delivery_address: Record<string, string | undefined>
  payment_due_at: string | null
  cancelled_at: string | null
  cancelled_reason: string | null
  cancelled_by_role: string | null
  can_cancel: boolean
  vendor_orders: VendorOrder[]
  payments: PaymentRecord[]
  refunds: RefundRecord[]
}
export interface FulfilmentItem {
  id: string
  vendor_order_number: string
  order_id: string
  order_number: string | null
  vendor_id: string
  vendor_name: string | null
  customer_id: string | null
  customer_name: string | null
  status: string
  order_status: string | null
  payment_method: string | null
  payment_status: string | null
  delivery_city: string | null
  delivery_postal_code: string | null
  item_count: number
  subtotal: number
  total_amount: number
  commission_amount: number | null
  accepted_at: string | null
  delivered_at: string | null
  created_at: string
}

// ------------------------------------------------------------------ services & bookings
export interface ServiceCategory {
  id: string
  name: string
  slug: string
  description: string | null
  image_url: string | null
  image_path: string | null
  sort_order: number
  is_active: boolean
  service_count?: number | null
  booking_count?: number | null
  created_at: string
  updated_at: string
}
export interface AdminService {
  id: string
  service_category_id: string
  category: { id: string; name: string; slug: string } | null
  name: string
  description: string | null
  price: number
  estimated_duration_minutes: number | null
  is_active: boolean
  is_available: boolean
  available_days: string[] | null
  slot_minutes: number
  max_bookings_per_slot: number
  created_at: string
  updated_at: string
  vendor_id: string
  vendor_name: string | null
  vendor_status: string | null
}
export interface Pickup {
  id: string
  pickup_address: Record<string, string | undefined>
  dropoff_address: Record<string, string | undefined>
  pickup_status: string
  pickup_stage: string
  delivery_status: string
  delivery_stage: string
  scheduled_pickup_at: string | null
  scheduled_delivery_at: string | null
  picked_up_at: string | null
  delivered_at: string | null
  pickup_charge: number
  dropoff_charge: number
  customer_instructions: string | null
  notes: string | null
}
export interface Pricing {
  estimated_price: number
  additional_charges_total: number
  current_price: number
  pickup_charge: number
  dropoff_charge: number
  total_estimated: number
  total_current: number
  logistics_charges_configured: boolean | null
}
export interface BookingDetail extends AdminBookingItem {
  customer_id: string
  service_id: string | null
  service_category: { id?: string; name?: string } | null
  vendor: Record<string, unknown> | null
  vendor_admin: { id: string; business_name: string; city?: string; state?: string; contact_phone?: string; verification_status?: string } | null
  cycle: Record<string, string | null | undefined>
  issue_description: string
  estimated_duration_minutes: number | null
  needs_pickup_dropoff: boolean
  confirmed: { date: string | null; slot_start: string | null; slot_end: string | null }
  preferred: { date: string | null; slot_start: string | null; slot_end: string | null }
  pricing: Pricing
  pickup: Pickup | null
  charges: { id: string; amount: number; reason: string; recorded_role: string | null; created_at: string }[]
  notes: { id: string; author_role: string; note: string; created_at: string }[]
  images: { id: string; storage_path: string; url: string | null }[]
  rejection_reason: string | null
  cancellation_reason: string | null
  completion_notes: string | null
  accepted_at: string | null
  completed_at: string | null
}
export interface BookingListItem extends AdminBookingItem {
  service_category: string | null
  needs_pickup_dropoff: boolean
  pickup_stage: string | null
  delivery_stage: string | null
  confirmed: { date: string | null; slot_start: string | null }
}
export interface PickupItem {
  id: string
  booking_id: string
  booking_number: string | null
  booking_status: string | null
  service_name: string | null
  vendor_name: string | null
  customer: { full_name: string | null; phone: string | null } | null
  pickup: Pickup
  preferred: { date: string | null; slot_start: string | null }
}
export interface Ticket {
  id: string
  ticket_number: string
  type: 'complaint' | 'support_request' | 'dispute'
  subject: string
  description: string
  status: 'open' | 'in_progress' | 'resolved' | 'closed'
  order_id: string | null
  service_booking_id: string | null
  resolution: string | null
  resolved_at: string | null
  created_at: string
  updated_at: string
  requester_id: string
  assigned_to: string | null
  admin_notes: string | null
}

// ------------------------------------------------------------------ finance
export interface SettlementRecord {
  id: string
  vendor_id: string
  vendor_name: string | null
  vendor_order_id: string
  order_number: string | null
  gross_amount: number
  commission_amount: number
  deductions_amount: number
  net_amount: number
  status: 'pending' | 'ready' | 'paid' | 'cancelled'
  payout_reference: string | null
  settled_at: string | null
  created_at: string
  notes: string | null
}
export interface SettlementPage extends Page<SettlementRecord> {
  summary: Record<string, number>
}
export interface CommissionRule {
  id: string
  name: string
  applies_to: 'product' | 'service'
  vendor_id: string | null
  category_id: string | null
  service_category_id: string | null
  commission_type: 'percentage' | 'fixed'
  commission_value: number
  priority: number
  is_active: boolean
  effective_from: string
  effective_until: string | null
  created_at: string
  vendor_name: string | null
  category_name: string | null
  service_category_name: string | null
  scope: 'global' | 'vendor' | 'category' | 'vendor_and_category' | 'service_category'
  state: 'active' | 'inactive' | 'scheduled' | 'expired'
}
export interface CommissionRuleInput {
  name: string
  applies_to: 'product' | 'service'
  vendor_id?: string | null
  category_id?: string | null
  service_category_id?: string | null
  commission_type: 'percentage' | 'fixed'
  commission_value: number
  priority: number
  is_active: boolean
  effective_from?: string | null
  effective_until?: string | null
}
export interface ProviderInfo { configured: boolean; provider: string | null; refunds_via_provider: boolean }
export interface PaymentDetail extends PaymentRecord {
  order: { id: string; order_number: string; status: string; payment_status: string; total_amount: number } | null
  events: { id: string; event_type: string; outcome: string; amount: number | null; created_at: string }[]
  refunds: RefundRecord[]
}

// ------------------------------------------------------------------ settings, coupons, communication, reports, audit
export interface Setting { key: string; value: unknown; configured: boolean; description: string; default_behaviour: string }
export interface DeliveryChargeValue { amount: number; free_above: number | null; per: 'order' | 'vendor_order' }
export interface Coupon {
  id: string
  code: string
  description: string | null
  discount_type: 'percentage' | 'fixed'
  discount_value: number
  max_discount_amount: number | null
  min_order_amount: number
  applies_to: 'products' | 'services' | 'all'
  valid_from: string
  valid_until: string | null
  usage_limit: number | null
  per_user_limit: number | null
  used_count: number
  is_active: boolean
  state: 'active' | 'inactive' | 'scheduled' | 'expired' | 'exhausted'
  created_at: string
  updated_at: string
}
export interface CouponInput {
  code?: string
  description?: string | null
  discount_type?: 'percentage' | 'fixed'
  discount_value?: number
  max_discount_amount?: number | null
  min_order_amount?: number
  applies_to?: 'products' | 'all'
  valid_from?: string | null
  valid_until?: string | null
  usage_limit?: number | null
  per_user_limit?: number | null
  is_active?: boolean
}
export type AnnouncementType = 'promotion' | 'announcement' | 'system'
export type Audience = 'customers' | 'vendors' | 'specific'
export interface Announcement {
  id: string
  title: string
  message: string
  type: AnnouncementType
  audience: Audience
  recipient_count: number
  delivered: number
  read: number
  push_sent: number
  push_failed: number
  push_pending: number
  created_by: string | null
  created_by_name: string | null
  created_at: string
  channel: string
}
export interface AnnouncementInput { title: string; message: string; type: AnnouncementType; audience: Audience; user_ids?: string[] }
export interface NotificationRecord {
  id: string
  user_id: string
  recipient_name: string | null
  recipient_role: string | null
  type: string
  title: string
  message: string
  related_type: string | null
  related_id: string | null
  is_read: boolean
  announcement_id: string | null
  created_at: string
  channel: string
  push_status: 'pending' | 'sending' | 'sent' | 'failed' | 'skipped' | 'expired'
  push_error: string | null
}
export interface PushStatus {
  configured: boolean
  provider: string | null
  dispatcher_enabled: boolean
  by_status: Record<string, number>
  active_devices: Record<string, number>
  oldest_pending: string | null
  recent_failures: { id: string; title: string; push_error: string | null; push_attempts: number; created_at: string }[]
}
export interface DispatchResult { configured: boolean; claimed: number; sent: number; retry: number; failed: number; skipped: number }
export type ReportKind = 'orders' | 'sales' | 'vendors' | 'customers' | 'services' | 'payments'
export interface Report<T = Record<string, unknown>> { kind: ReportKind; period_from: string; period_to: string; timezone: string; data: T }
export interface CountValue { count: number; amount: number }
export interface AuditRecord {
  id: string
  actor_id: string | null
  actor_name: string | null
  actor_role: string | null
  action: string
  entity_type: string
  entity_id: string | null
  details: Record<string, unknown>
  created_at: string
}

export interface TimelineEvent {
  at: string
  scope: 'order' | 'vendor_order' | 'booking'
  vendor_order_id: string | null
  vendor_name: string | null
  from_status: string | null
  to_status: string
  note: string | null
  changed_by_id: string | null
  changed_by_name: string | null
  changed_by_role: string | null
}
