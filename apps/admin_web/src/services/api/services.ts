import type {
  AccountStatus, AdminBookingItem, AdminOrder, AdminOrderItem, AdminProduct, AdminProductItem, AdminService, Announcement, AnnouncementInput, AuditRecord, Banner, BannerInput,
  BookingDetail, BookingListItem, BusinessType, Category, CategoryInput, CommissionRule, CommissionRuleInput, Coupon, CouponInput, CustomerDetail, CustomerListItem, Dashboard,
  DispatchResult, FulfilmentItem, Me, NotificationRecord, Page, PaymentDetail, PaymentRecord, PickupItem, Profile, ProviderInfo, PushStatus, RefundRecord, Report, ReportKind, RevenueSummary, ServiceCategory,
  Setting, SettlementPage, SortBy, Ticket, TimelineEvent, VendorDetail, VendorListItem, VerificationStatus,
} from '../../types/api'
import type { ApiClient } from './client'

export interface ListParams {
  q?: string
  page?: number
  limit?: number
  sort?: SortBy
}

export interface CustomerQuery extends ListParams {
  status?: AccountStatus | ''
}
export interface VendorQuery extends ListParams {
  business_type?: BusinessType | ''
  verification_status?: VerificationStatus | ''
  account_status?: AccountStatus | ''
}

type Q = Record<string, string | number | boolean | null | undefined>
/** Filters shared by most Step 10 lists: free text, status, dates and paging (empty values never reach the URL). */
export interface Filters extends Q {
  q?: string
  page?: number
  limit?: number
}

/** A fresh Idempotency-Key for a state-changing request that must not be applied twice (refund creation). */
export function newIdempotencyKey(): string {
  return `adm-${typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`}`
}

/** All business data comes from FastAPI. There is no direct database access from this app. */
export function createServices(api: ApiClient) {
  const auth = {
    /** The BACKEND's verdict on who this token belongs to (role + status come from the database, never from the browser). */
    me: () => api.get<Me>('/auth/me'),
    logout: () => api.post<unknown>('/auth/logout'),
  }

  const dashboard = {
    summary: (from?: string, to?: string) => api.get<Dashboard>('/admin/dashboard', { from, to }),
    payments: (from?: string, to?: string) => api.get<RevenueSummary>('/admin/payments/summary', { from, to }),
    recentOrders: (limit = 5) => api.get<Page<AdminOrderItem>>('/admin/orders', { limit }),
    recentBookings: (limit = 5) => api.get<Page<AdminBookingItem>>('/admin/service-bookings', { limit }),
  }

  const customers = {
    list: (p: CustomerQuery) => api.get<Page<CustomerListItem>>('/admin/customers', { ...p }),
    get: (id: string) => api.get<CustomerDetail>(`/admin/customers/${id}`),
    setStatus: (id: string, status: AccountStatus, reason?: string) => api.patch<CustomerDetail>(`/admin/customers/${id}/status`, { status, reason: reason || undefined }),
    orders: (id: string, limit = 10) => api.get<Page<AdminOrderItem>>('/admin/orders', { customer_id: id, limit }),
    bookings: (id: string, limit = 10) => api.get<Page<AdminBookingItem>>('/admin/service-bookings', { customer_id: id, limit }),
  }

  const vendors = {
    list: (p: VendorQuery) => api.get<Page<VendorListItem>>('/admin/vendors', { ...p }),
    get: (id: string) => api.get<VendorDetail>(`/admin/vendors/${id}`),
    approve: (id: string, note?: string) => api.post<VendorDetail>(`/admin/vendors/${id}/approve`, note ? { note } : {}),
    reject: (id: string, reason: string) => api.post<VendorDetail>(`/admin/vendors/${id}/reject`, { reason }),
    suspend: (id: string, reason: string) => api.post<VendorDetail>(`/admin/vendors/${id}/suspend`, { reason }),
    reinstate: (id: string, note?: string) => api.post<VendorDetail>(`/admin/vendors/${id}/reinstate`, note ? { note } : {}),
    setAccountStatus: (id: string, status: AccountStatus, reason?: string) => api.patch<VendorDetail>(`/admin/vendors/${id}/account-status`, { status, reason: reason || undefined }),
    products: (id: string, limit = 10) => api.get<Page<AdminProductItem>>('/admin/products', { vendor_id: id, limit }),
    orders: (id: string, limit = 10) => api.get<Page<AdminOrderItem>>('/admin/orders', { vendor_id: id, limit }),
    bookings: (id: string, limit = 10) => api.get<Page<AdminBookingItem>>('/admin/service-bookings', { vendor_id: id, limit }),
  }

  const profile = {
    get: () => api.get<Profile>('/profiles/me'),
    /** Only name and phone: role, status and e-mail are not accepted by the backend (422). */
    update: (v: { full_name?: string; phone?: string }) => api.put<Profile>('/profiles/me', v),
  }

  // ------------------------------------------------------------------ marketplace
  const products = {
    list: (p: Filters) => api.get<Page<AdminProduct>>('/admin/products', p),
    get: (id: string) => api.get<AdminProduct>(`/admin/products/${id}`),
    approve: (id: string) => api.patch<AdminProduct>(`/admin/products/${id}/approval`, { approval_status: 'approved' }),
    reject: (id: string, review_notes: string) => api.patch<AdminProduct>(`/admin/products/${id}/approval`, { approval_status: 'rejected', review_notes }),
    /** back to review (pending) */
    reset: (id: string) => api.patch<AdminProduct>(`/admin/products/${id}/approval`, { approval_status: 'pending' }),
    setActive: (id: string, is_active: boolean) => api.patch<AdminProduct>(`/admin/products/${id}/status`, { is_active }),
    setFeatured: (id: string, is_featured: boolean) => api.patch<AdminProduct>(`/admin/products/${id}/featured`, { is_featured }),
    history: (id: string) => api.get<Page<AuditRecord>>('/admin/audit-log', { entity_type: 'product', entity_id: id, limit: 20 }),
  }

  const categories = {
    list: (kind?: string) => api.get<Category[]>('/admin/categories', { kind }),
    create: (v: CategoryInput) => api.post<Category>('/admin/categories', v),
    update: (id: string, v: Partial<CategoryInput>) => api.put<Category>(`/admin/categories/${id}`, v),
    remove: (id: string) => api.delete<void>(`/admin/categories/${id}`),
  }

  const banners = {
    list: () => api.get<Banner[]>('/admin/banners'),
    create: (v: BannerInput) => api.post<Banner>('/admin/banners', v),
    update: (id: string, v: BannerInput) => api.put<Banner>(`/admin/banners/${id}`, v),
    remove: (id: string) => api.delete<void>(`/admin/banners/${id}`),
  }

  // ------------------------------------------------------------------ orders & fulfilment
  const orders = {
    list: (p: Filters) => api.get<Page<AdminOrder>>('/admin/orders', p),
    get: (id: string) => api.get<AdminOrder>(`/admin/orders/${id}`),
    cancel: (id: string, reason: string) => api.patch<AdminOrder>(`/admin/orders/${id}/status`, { status: 'cancelled', reason }),
    setVendorOrderStatus: (id: string, vendor_order_id: string, status: string, reason?: string) =>
      api.patch<AdminOrder>(`/admin/orders/${id}/status`, { status, vendor_order_id, reason: reason || undefined }),
    timeline: (id: string) => api.get<TimelineEvent[]>(`/admin/orders/${id}/timeline`),
    tickets: (id: string) => api.get<Page<Ticket>>('/admin/support-tickets', { order_id: id, limit: 20 }),
  }

  const fulfilment = {
    list: (p: Filters) => api.get<Page<FulfilmentItem>>('/admin/vendor-orders', p),
  }

  // ------------------------------------------------------------------ services & bookings
  const serviceCategories = {
    list: () => api.get<ServiceCategory[]>('/admin/service-categories'),
    create: (v: CategoryInput) => api.post<ServiceCategory>('/admin/service-categories', v),
    update: (id: string, v: Partial<CategoryInput>) => api.put<ServiceCategory>(`/admin/service-categories/${id}`, v),
    remove: (id: string) => api.delete<void>(`/admin/service-categories/${id}`),
  }

  const services = {
    list: (p: Filters) => api.get<Page<AdminService>>('/admin/services', p),
    get: (id: string) => api.get<AdminService>(`/admin/services/${id}`),
    setActive: (id: string, is_active: boolean, reason?: string) => api.patch<AdminService>(`/admin/services/${id}/status`, { is_active, reason: reason || undefined }),
  }

  const bookings = {
    list: (p: Filters) => api.get<Page<BookingListItem>>('/admin/service-bookings', p),
    get: (id: string) => api.get<BookingDetail>(`/admin/service-bookings/${id}`),
    setStatus: (id: string, status: string, reason?: string) => api.patch<BookingDetail>(`/admin/service-bookings/${id}/status`, { status, reason: reason || undefined }),
    tickets: (id: string) => api.get<Page<Ticket>>('/admin/support-tickets', { booking_id: id, limit: 20 }),
    timeline: (id: string) => api.get<TimelineEvent[]>(`/admin/service-bookings/${id}/timeline`),
  }

  const pickups = {
    list: (p: Filters) => api.get<Page<PickupItem>>('/admin/pickup-requests', p),
    coordinate: (id: string, v: { scheduled_pickup_at?: string | null; scheduled_delivery_at?: string | null; pickup_status?: string; delivery_status?: string; notes?: string }) =>
      api.patch<PickupItem>(`/admin/pickup-requests/${id}/status`, v),
  }

  const tickets = {
    update: (id: string, v: { status?: string; admin_notes?: string; resolution?: string }) => api.patch<Ticket>(`/admin/support-tickets/${id}`, v),
  }

  // ------------------------------------------------------------------ finance
  const payments = {
    list: (p: Filters) => api.get<Page<PaymentRecord>>('/admin/payments', p),
    get: (id: string) => api.get<PaymentDetail>(`/admin/payments/${id}`),
    summary: (from?: string, to?: string) => api.get<RevenueSummary & { settlements: Record<string, { count: number; net: number }> }>('/admin/payments/summary', { from, to }),
    provider: () => api.get<ProviderInfo>('/admin/payments/provider'),
    collectCod: (id: string) => api.post<unknown>(`/admin/payments/${id}/collect-cod`),
    reconcile: (id: string) => api.post<unknown>(`/admin/payments/${id}/reconcile`),
  }

  const refunds = {
    list: (p: Filters) => api.get<Page<RefundRecord>>('/admin/refunds', p),
    get: (id: string) => api.get<RefundRecord>(`/admin/refunds/${id}`),
    /** The backend requires an Idempotency-Key; the caller keeps one key per form so a double click returns the same refund. */
    create: (v: { payment_id: string; amount: number; reason: string }, key: string) => api.post<RefundRecord>('/admin/refunds', v, { 'Idempotency-Key': key }),
    act: (id: string, v: { action: 'approve' | 'reject' | 'process' | 'fail'; manual?: boolean; provider_refund_id?: string; note?: string }) => api.post<RefundRecord>(`/admin/refunds/${id}/actions`, v),
  }

  const commission = {
    list: () => api.get<CommissionRule[]>('/admin/commission-rules'),
    create: (v: CommissionRuleInput) => api.post<CommissionRule>('/admin/commission-rules', v),
    update: (id: string, v: Partial<Pick<CommissionRuleInput, 'name' | 'commission_type' | 'commission_value' | 'priority' | 'is_active' | 'effective_until'>>) =>
      api.put<CommissionRule>(`/admin/commission-rules/${id}`, v),
    resolve: (vendor_id?: string, category_id?: string) => api.get<{ rule: CommissionRule | null; note: string | null }>('/admin/commission-rules/resolve', { vendor_id, category_id }),
    history: () => api.get<Page<AuditRecord>>('/admin/audit-log', { entity_type: 'commission_rule', limit: 20 }),
  }

  const settlements = {
    list: (p: Filters) => api.get<SettlementPage>('/admin/settlements', p),
  }

  // ------------------------------------------------------------------ communication, coupons, settings, reports, audit
  const communication = {
    announcements: (p: Filters) => api.get<Page<Announcement>>('/admin/announcements', p),
    send: (v: AnnouncementInput) => api.post<Announcement>('/admin/announcements', v),
    records: (p: Filters) => api.get<Page<NotificationRecord>>('/admin/notifications', p),
    pushStatus: () => api.get<PushStatus>('/admin/push/status'),
    dispatchPush: () => api.post<DispatchResult>('/admin/push/dispatch'),
  }

  const coupons = {
    list: (p: Filters) => api.get<Page<Coupon>>('/admin/coupons', p),
    create: (v: CouponInput) => api.post<Coupon>('/admin/coupons', v),
    update: (id: string, v: CouponInput) => api.put<Coupon>(`/admin/coupons/${id}`, v),
  }

  const settings = {
    list: () => api.get<Setting[]>('/admin/settings'),
    put: (key: string, value: unknown) => api.put<Setting>(`/admin/settings/${key}`, { value }),
    history: () => api.get<Page<AuditRecord>>('/admin/audit-log', { entity_type: 'setting', limit: 20 }),
  }

  const reports = {
    get: <T = Record<string, unknown>>(kind: ReportKind, from?: string, to?: string) => api.get<Report<T>>(`/admin/reports/${kind}`, { from, to }),
  }

  return {
    auth, dashboard, customers, vendors, profile,
    products, categories, banners, orders, fulfilment, serviceCategories, services, bookings, pickups, tickets,
    payments, refunds, commission, settlements, communication, coupons, settings, reports,
  }
}

export type Services = ReturnType<typeof createServices>
