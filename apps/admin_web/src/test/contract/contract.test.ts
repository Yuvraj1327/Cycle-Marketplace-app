import { beforeAll, describe, expect, it } from 'vitest'
import { ApiError, createApiClient } from '../../services/api/client'
import { createServices } from '../../services/api/services'

const base = process.env.CONTRACT_API
interface Seed { customer: string; other: string; admin: string; vendor_id: string; vendor_b_id: string; tokens: Record<string, string>; expired: string; address_id: string; product_ids: Record<string, string> }

describe.skipIf(!base)('admin console ↔ real FastAPI backend (dev harness)', () => {
  let seed: Seed
  const as = (who: string, onSessionExpired?: () => void) => createServices(createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => (who === 'none' ? null : who === 'expired' ? seed.expired : seed.tokens[who]), onSessionExpired }))
  const admin = () => as('admin')
  const fail = (p: Promise<unknown>) => p.then(() => { throw new Error('expected the request to fail') }, (e: unknown) => e as ApiError)
  let vendors: Record<string, string> = {}

  beforeAll(async () => {
    await fetch(`${base}/__dev/reset`, { method: 'POST' })
    seed = (await (await fetch(`${base}/__dev/tokens`)).json()) as Seed
    const all = await admin().vendors.list({ limit: 100 })
    vendors = Object.fromEntries(all.items.map((v) => [v.business_name, v.id]))
  })

  describe('authentication and RBAC', () => {
    it('the backend identifies the admin; customers and vendors are not admins', async () => {
      expect((await admin().auth.me()).role).toBe('admin')
      expect((await as('customer').auth.me()).role).toBe('customer')
      expect((await as('vendor_user').auth.me()).role).toBe('vendor')
    })
    it('every admin endpoint refuses anonymous, expired-token, customer and vendor callers', async () => {
      const calls = (s: ReturnType<typeof as>) => [() => s.dashboard.summary(), () => s.customers.list({}), () => s.customers.get(seed.customer), () => s.customers.setStatus(seed.customer, 'inactive', 'abc'),
        () => s.vendors.list({}), () => s.vendors.get(seed.vendor_id), () => s.vendors.approve(seed.vendor_id), () => s.vendors.reject(seed.vendor_id, 'reason'), () => s.vendors.suspend(seed.vendor_id, 'reason'),
        () => s.vendors.reinstate(seed.vendor_id), () => s.vendors.setAccountStatus(seed.vendor_id, 'inactive', 'reason')]
      for (const [who, kind] of [['none', 'unauthorized'], ['expired', 'unauthorized'], ['customer', 'forbidden'], ['vendor_user', 'forbidden'], ['vendor_pending', 'forbidden']] as const) {
        for (const call of calls(as(who))) expect(await fail(call()), who).toMatchObject({ kind })
      }
    })
    it('an expired token reports the session as expired to the app', async () => {
      let expired = 0
      await fail(as('expired', () => expired++).customers.list({}))
      expect(expired).toBe(1)
    })
    it('no request can raise an account to admin', async () => {
      const api = createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.admin })
      expect(await fail(api.patch(`/admin/customers/${seed.customer}/status`, { status: 'active', role: 'admin' }))).toMatchObject({ status: 422 })
      expect(await fail(createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.customer }).put('/profiles/me', { role: 'admin' }))).toMatchObject({ status: 422 })
      expect((await as('customer').auth.me()).role).toBe('customer')
    })
  })

  describe('dashboard', () => {
    it('returns real counts and a complete daily series', async () => {
      const d = await admin().dashboard.summary('2026-01-01', '2026-01-05')
      expect(d.customers.total).toBe(2)
      expect(d.vendors.total).toBe(5)
      expect(d.vendors.by_verification).toMatchObject({ approved: 2, pending: 1, rejected: 1, suspended: 1 })
      expect(d.series.orders.map((x) => x.day)).toEqual(['2026-01-01', '2026-01-02', '2026-01-03', '2026-01-04', '2026-01-05'])
      expect(d.series.customers.reduce((n, x) => n + x.count, 0)).toBe(d.customers.new_in_period)
    })
    it('rejects bad periods; payments summary is available; recent orders are readable', async () => {
      expect(await fail(admin().dashboard.summary('2026-02-01', '2026-01-01'))).toMatchObject({ status: 422 })
      expect(await fail(admin().dashboard.summary('2020-01-01', '2026-01-01'))).toMatchObject({ status: 422 })
      expect((await admin().dashboard.payments()).collected).toBeTypeOf('number')
      expect((await admin().dashboard.recentOrders(5)).items).toBeInstanceOf(Array)
    })
  })

  describe('customers', () => {
    it('lists only customers, with counts; search / filter / pagination happen on the server', async () => {
      const s = admin()
      const all = await s.customers.list({})
      expect(all.total).toBe(2)
      expect(all.items.map((c) => c.id).sort()).toEqual([seed.customer, seed.other].sort())
      expect(all.items.every((c) => c.order_count !== null && c.booking_count !== null)).toBe(true)
      expect((await s.customers.list({ q: 'asha' })).items.map((c) => c.id)).toEqual([seed.customer])
      expect((await s.customers.list({ q: '+9198000' })).items.map((c) => c.id)).toEqual([seed.customer])
      expect((await s.customers.list({ status: 'restricted' })).total).toBe(0)
      const p = await s.customers.list({ limit: 1, page: 2, sort: 'name' })
      expect(p).toMatchObject({ total: 2, pages: 2, page: 2 })
      expect(p.items).toHaveLength(1)
      expect(await fail(s.customers.list({ status: 'bogus' as never }))).toMatchObject({ status: 422 })
    })
    it('detail includes addresses; history comes from the existing admin order/booking APIs', async () => {
      const d = await admin().customers.get(seed.customer)
      expect(d.addresses[0].address_line1).toBe('12 MG Road')
      expect(d.activity).toEqual([])
      expect((await admin().customers.orders(seed.customer)).items).toBeInstanceOf(Array)
      expect(await fail(admin().customers.get(seed.admin))).toMatchObject({ kind: 'not_found' })
    })
    it('deactivate → blocked by the backend → repeated request refused → activate; history kept; audit trail written', async () => {
      const s = admin()
      expect(await fail(s.customers.setStatus(seed.customer, 'inactive'))).toMatchObject({ status: 422 })           // reason required
      const off = await s.customers.setStatus(seed.customer, 'inactive', 'Fraud report #7')
      expect(off.status).toBe('inactive')
      expect(off.activity[0]).toMatchObject({ action: 'customer_inactive', details: { reason: 'Fraud report #7' } })
      expect(await fail(s.customers.setStatus(seed.customer, 'inactive', 'again please'))).toMatchObject({ kind: 'conflict' })
      expect(await fail(as('customer').auth.me().then(() => createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.customer }).get('/addresses')))).toMatchObject({ kind: 'forbidden' })
      expect((await s.customers.setStatus(seed.customer, 'active')).status).toBe('active')
      expect((await s.customers.get(seed.customer)).activity).toHaveLength(2)
    })
  })

  describe('vendors', () => {
    it('lists vendors with owner, counts and filters', async () => {
      const s = admin()
      expect((await s.vendors.list({ verification_status: 'pending' })).items.map((v) => v.business_name)).toEqual(['Pending Cycles'])
      expect((await s.vendors.list({ verification_status: 'rejected' })).total).toBe(1)
      expect((await s.vendors.list({ q: 'gear' })).items.map((v) => v.business_name)).toEqual(['Gear Garage'])
      expect((await s.vendors.list({ q: 'suspended vendor' })).items.map((v) => v.business_name)).toEqual(['Suspended Cycles'])
      expect((await s.vendors.list({ business_type: 'service_provider' })).total).toBe(0)
      expect((await s.vendors.list({ account_status: 'active' })).total).toBe(5)
      expect((await s.vendors.list({ account_status: 'inactive' })).total).toBe(0)
      const a = (await s.vendors.list({ q: 'Spoke' })).items[0]
      expect(a).toMatchObject({ business_name: 'Spoke & Co', verification_status: 'approved', account_status: 'active', product_count: 3 })
    })
    it('detail shows the whole application', async () => {
      const d = await admin().vendors.get(vendors['Spoke & Co'])
      expect(d.address_line1).toBeTruthy()
      expect(d.operating_hours.mon).toMatchObject({ open: '09:00' })
      expect(d.service_area_postal_codes).toEqual(['411001', '411002'])
      expect(d.pickup_available).toBe(true)
      expect((await admin().vendors.products(d.id)).total).toBe(3)
    })
    it('approve a pending application: the vendor can then operate; repeating is refused; audit + notification recorded', async () => {
      const s = admin()
      const id = vendors['Pending Cycles']
      const vendorApi = as('vendor_pending')
      expect(await fail(vendorApi.auth.me().then(() => createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.vendor_pending }).get('/vendor/dashboard')))).toMatchObject({ kind: 'forbidden' })
      const ok = await s.vendors.approve(id, 'Documents verified')
      expect(ok).toMatchObject({ verification_status: 'approved', review_notes: 'Documents verified' })
      expect(ok.reviewed_at).toBeTruthy()
      expect(ok.activity[0].action).toBe('vendor_approved')
      expect(await fail(s.vendors.approve(id))).toMatchObject({ kind: 'conflict', code: 'already_approved' })
      const vApi = createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.vendor_pending })
      expect(await vApi.get('/vendor/dashboard')).toMatchObject({ orders: { total: 0 } })
      const notes = await createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.vendor_pending }).get<{ items: { title: string }[] }>('/notifications')
      expect(notes.items.map((n) => n.title)).toContain('Application approved')
    })
    it('reject needs a reason; a rejected vendor can be approved after review; approved vendors cannot be rejected', async () => {
      const s = admin()
      const id = vendors['Rejected Cycles']
      expect(await fail(s.vendors.reject(id, 'second reason'))).toMatchObject({ kind: 'conflict' })               // already rejected
      expect(await fail(s.vendors.reject(vendors['Spoke & Co'], 'too late now'))).toMatchObject({ kind: 'conflict' })
      expect(await fail(createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.admin }).post(`/admin/vendors/${id}/reject`, {}))).toMatchObject({ status: 422 })
      expect((await s.vendors.approve(id)).verification_status).toBe('approved')
    })
    it('suspend blocks the vendor everywhere; reinstate restores; reasons required', async () => {
      const s = admin()
      const id = vendors['Gear Garage']
      const vb = createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.vendor_b_user })
      expect(await vb.get('/vendor/dashboard')).toBeTruthy()
      expect(await fail(createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.admin }).post(`/admin/vendors/${id}/suspend`, {}))).toMatchObject({ status: 422 })
      const sus = await s.vendors.suspend(id, 'Counterfeit parts')
      expect(sus).toMatchObject({ verification_status: 'suspended', rejection_reason: 'Counterfeit parts' })
      expect(await fail(vb.get('/vendor/dashboard'))).toMatchObject({ kind: 'forbidden' })
      expect(await fail(s.vendors.suspend(id, 'once more please'))).toMatchObject({ kind: 'conflict' })
      expect((await s.vendors.products(id)).total).toBe(2)                 // history is kept
      expect((await s.vendors.reinstate(id)).verification_status).toBe('approved')
      expect(await vb.get('/vendor/dashboard')).toBeTruthy()
    })
    it('account status is separate from verification', async () => {
      const s = admin()
      const id = vendors['Gear Garage']
      expect(await fail(s.vendors.setAccountStatus(id, 'inactive'))).toMatchObject({ status: 422 })
      const off = await s.vendors.setAccountStatus(id, 'inactive', 'Owner request')
      expect(off).toMatchObject({ account_status: 'inactive', verification_status: 'approved' })
      expect((await s.vendors.list({ account_status: 'inactive' })).items.map((v) => v.id)).toEqual([id])
      expect(await fail(createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.vendor_b_user }).get('/vendor/dashboard'))).toMatchObject({ kind: 'forbidden' })
      expect((await s.vendors.setAccountStatus(id, 'active')).account_status).toBe('active')
    })
    it('unknown vendor → 404', async () => {
      expect(await fail(admin().vendors.get('00000000-0000-0000-0000-000000000000'))).toMatchObject({ kind: 'not_found' })
    })
  })

  describe('admin profile', () => {
    it('reads and updates only name/phone', async () => {
      const s = admin()
      const p = await s.profile.get()
      expect(p.role).toBe('admin')
      const u = await s.profile.update({ full_name: 'Platform Admin' })
      expect(u).toMatchObject({ full_name: 'Platform Admin', role: 'admin', status: 'active' })
      expect(await fail(createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.admin }).put('/profiles/me', { role: 'customer' }))).toMatchObject({ status: 422 })
    })
  })
})
