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
