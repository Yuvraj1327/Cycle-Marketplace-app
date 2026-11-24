import type {
  AccountStatus, AdminBookingItem, AdminOrderItem, AdminProductItem, BusinessType, CustomerDetail, CustomerListItem, Dashboard, Me, Page, Profile, RevenueSummary,
  SortBy, VendorDetail, VendorListItem, VerificationStatus,
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

  return { auth, dashboard, customers, vendors, profile }
}

export type Services = ReturnType<typeof createServices>
