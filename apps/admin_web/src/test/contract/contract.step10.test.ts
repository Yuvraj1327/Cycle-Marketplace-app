import { beforeAll, describe, expect, it } from 'vitest'
import { ApiError, createApiClient } from '../../services/api/client'
import { createServices, newIdempotencyKey } from '../../services/api/services'
import type { AdminOrder, BookingDetail } from '../../types/api'

/** Step 10 admin modules against the REAL FastAPI application (backend/tests/dev_server.py: in-memory database, locally signed JWTs).
 *  This is NOT a test against a real Supabase project, real Storage or a real payment gateway. */
const base = process.env.CONTRACT_API
interface Seed { customer: string; other: string; admin: string; vendor_id: string; vendor_b_id: string; vendor_user: string; tokens: Record<string, string>; expired: string; address_id: string; product_ids: Record<string, string>; category_ids: Record<string, string>; service_id: string; service_category_id: string; day: string }

describe.skipIf(!base)('Step 10 admin modules ↔ real FastAPI backend (dev harness)', () => {
  let seed: Seed
  const client = (who: string) => createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => (who === 'none' ? null : who === 'expired' ? seed.expired : seed.tokens[who]) })
  const as = (who: string) => createServices(client(who))
  const admin = () => as('admin')
  const fail = (p: Promise<unknown>) => p.then(() => { throw new Error('expected the request to fail') }, (e: unknown) => e as ApiError)
  let n = 0
  /** a customer places a real COD order through the real checkout */
  async function placeOrder(productName: string, qty = 1, extra: Record<string, unknown> = {}) {
    const c = client('customer')
    await c.post('/cart/items', { product_id: seed.product_ids[productName], quantity: qty })
    const r = await c.post<{ order: AdminOrder }>('/checkout', { delivery_address_id: seed.address_id, payment_method: 'cod', ...extra }, { 'Idempotency-Key': `contract-key-${++n}-${Date.now()}` })
    return r.order
  }
  const vendorAdvance = async (vendorOrderId: string, who = 'vendor_user') => {
    const v = client(who)
    await v.post(`/vendor/orders/${vendorOrderId}/accept`, {})
    for (const status of ['preparing', 'ready_for_dispatch', 'delivered']) await v.patch(`/vendor/orders/${vendorOrderId}/status`, { status })
  }

  beforeAll(async () => {
    await fetch(`${base}/__dev/reset`, { method: 'POST' })
    seed = (await (await fetch(`${base}/__dev/tokens`)).json()) as Seed
  })

  describe('RBAC', () => {
    it('every Step 10 admin endpoint refuses anonymous, expired, customer and vendor callers', async () => {
      const id = '00000000-0000-0000-0000-000000000001'
      const calls = (s: ReturnType<typeof as>) => [() => s.products.list({}), () => s.products.get(id), () => s.products.approve(id), () => s.products.setActive(id, false), () => s.products.setFeatured(id, true), () => s.categories.list(), () => s.categories.create({ name: 'Zed', kind: 'accessory' }),
        () => s.banners.list(), () => s.banners.create({ title: 'x', image_path: 'banners/x.jpg' }), () => s.orders.list({}), () => s.orders.get(id), () => s.orders.cancel(id, 'reason'), () => s.orders.timeline(id), () => s.fulfilment.list({}),
        () => s.serviceCategories.list(), () => s.services.list({}), () => s.services.setActive(id, false, 'reason'), () => s.bookings.list({}), () => s.bookings.get(id), () => s.bookings.timeline(id), () => s.pickups.list({}),
        () => s.payments.list({}), () => s.payments.get(id), () => s.payments.provider(), () => s.refunds.list({}), () => s.refunds.create({ payment_id: id, amount: 1, reason: 'abc' }, 'key-12345678'), () => s.commission.list(), () => s.commission.resolve(),
        () => s.settlements.list({}), () => s.communication.announcements({}), () => s.communication.send({ title: 'abc', message: 'abc', type: 'announcement', audience: 'customers' }), () => s.communication.records({}),
        () => s.communication.pushStatus(), () => s.communication.dispatchPush(), () => s.coupons.list({}), () => s.coupons.create({ code: 'ABC', discount_type: 'fixed', discount_value: 1 }), () => s.settings.list(), () => s.settings.put('payments.cod_enabled', true), () => s.reports.get('orders'), () => s.settings.history()]
      for (const [who, kind] of [['none', 'unauthorized'], ['expired', 'unauthorized'], ['customer', 'forbidden'], ['vendor_user', 'forbidden'], ['vendor_pending', 'forbidden']] as const) {
        for (const call of calls(as(who))) expect(await fail(call()), who).toMatchObject({ kind })
      }
    })
  })

  describe('marketplace', () => {
    it('lists, sorts and filters products on the server, with vendor, category and stock', async () => {
      const s = admin()
      const all = await s.products.list({ limit: 100 })
      expect(all.total).toBe(5)
      expect(all.items[0].vendor?.business_name).toBeTruthy()
      expect(all.items[0].category?.name).toBeTruthy()
      expect((await s.products.list({ sort: 'price_high_to_low' })).items[0].name).toBe('Trail Blazer 29')
      expect((await s.products.list({ sort: 'name' })).items[0].name).toBe('City Cruiser')
      expect((await s.products.list({ in_stock: false })).items.map((p) => p.name)).toEqual(['Road Helmet'])
      expect((await s.products.list({ condition: 'used' })).items.map((p) => p.name)).toEqual(['Old Commuter'])
      expect((await s.products.list({ vendor_id: seed.vendor_id })).total).toBe(3)
      expect((await s.products.list({ category_id: seed.category_ids.spare_part })).total).toBe(1)
      expect((await s.products.list({ is_featured: true })).total).toBe(2)
      expect(await fail(s.products.list({ sort: 'bogus' }))).toMatchObject({ status: 422 })
    })

    it('moderation: rejection needs a note; every decision is audited with the admin; deactivating removes the featured flag; vendors cannot moderate', async () => {
      const s = admin()
      const id = seed.product_ids['City Cruiser']
      expect(await fail(s.products.reject(id, ''))).toMatchObject({ status: 422 })
      expect((await s.products.reject(id, 'Photos are unclear')).approval_status).toBe('rejected')
      expect((await s.products.approve(id)).approval_status).toBe('approved')
      expect((await s.products.setFeatured(id, true)).is_featured).toBe(true)
      const off = await s.products.setActive(id, false)
      expect([off.is_active, off.is_featured]).toEqual([false, false])
      expect(await fail(s.products.setFeatured(id, true))).toMatchObject({ kind: 'conflict' })
      const history = await s.products.history(id)
      expect(history.items.map((a) => a.action)).toEqual(['product_deactivated', 'product_featured', 'product_approval_changed', 'product_approval_changed'])
      expect(history.items[0]).toMatchObject({ actor_role: 'admin', entity_type: 'product' })
      expect(await fail(createApiClient({ baseUrl: `${base}/api/v1`, getToken: async () => seed.tokens.vendor_b_user }).patch(`/admin/products/${id}/approval`, { approval_status: 'approved' }))).toMatchObject({ kind: 'forbidden' })
      await s.products.setActive(id, true)
    })

    it('categories: create with validation, unique names, safe delete', async () => {
      const s = admin()
      const created = await s.categories.create({ name: 'Child Seats', kind: 'accessory', description: 'Safety seats', sort_order: 9 })
      expect(created).toMatchObject({ name: 'Child Seats', kind: 'accessory', is_active: true, product_count: 0 })
      expect(await fail(s.categories.create({ name: 'Child Seats', kind: 'accessory' }))).toMatchObject({ kind: 'conflict' })
      expect(await fail(s.categories.create({ name: 'x', kind: 'accessory' }))).toMatchObject({ status: 422 })
      expect(await fail(s.categories.create({ name: 'Bad image', kind: 'accessory', image_path: '../etc/passwd.jpg' }))).toMatchObject({ status: 422 })
      expect((await s.categories.update(created.id, { is_active: false })).is_active).toBe(false)
      expect(await fail(s.categories.remove(seed.category_ids.new_cycle))).toMatchObject({ kind: 'conflict' })          // products depend on it
      await s.categories.remove(created.id)
      expect((await s.categories.list()).some((c) => c.id === created.id)).toBe(false)
    })

    it('banners: create / reorder / deactivate / remove; unsafe paths and bad links are refused', async () => {
      const s = admin()
      const b = await s.banners.create({ title: 'Monsoon', image_path: 'banners/monsoon.jpg', action_type: 'url', action_value: 'https://shop.test/sale', sort_order: 5 })
      expect(b).toMatchObject({ title: 'Monsoon', is_active: true, sort_order: 5 })
      expect(await fail(s.banners.create({ title: 'x', image_path: '../x.jpg' }))).toMatchObject({ status: 422 })
      expect(await fail(s.banners.create({ title: 'x', image_path: 'banners/x.jpg', action_type: 'url', action_value: 'http://insecure' }))).toMatchObject({ status: 422 })
      expect((await s.banners.update(b.id, { sort_order: 0 })).sort_order).toBe(0)
      expect((await s.banners.update(b.id, { is_active: false })).is_active).toBe(false)
      expect((await s.banners.list()).map((x) => x.id)).toContain(b.id)
      await s.banners.remove(b.id)
      expect((await s.banners.list()).map((x) => x.id)).not.toContain(b.id)
    })
  })

  describe('orders, fulfilment, payments, refunds, commission, settlements', () => {
    let order: AdminOrder

    it('a real checkout appears in the admin list; search by customer, vendor and number, date and sort work', async () => {
      order = await placeOrder('Trail Blazer 29', 2)
      const s = admin()
      const today = new Date().toISOString().slice(0, 10)
      const list = await s.orders.list({})
      expect(list.total).toBe(1)
      expect(list.items[0]).toMatchObject({ order_number: order.order_number, status: 'confirmed', payment_method: 'cod' })
      expect(list.items[0].customer?.full_name).toBe('Asha Rao')
      expect((await s.orders.list({ q: 'asha' })).total).toBe(1)
      expect((await s.orders.list({ q: 'Spoke' })).total).toBe(1)
      expect((await s.orders.list({ q: 'Gear Garage' })).total).toBe(0)
      expect((await s.orders.list({ q: order.order_number })).total).toBe(1)
      expect((await s.orders.list({ q: 'nobody-at-all' })).total).toBe(0)
      expect((await s.orders.list({ date_from: '2020-01-01', date_to: '2020-01-02' })).total).toBe(0)
      expect((await s.orders.list({ date_from: '2020-01-01', date_to: today })).total).toBe(1)
      expect((await s.orders.list({ sort: 'amount_high' })).total).toBe(1)
      expect(await fail(s.orders.list({ status: 'shipped' }))).toMatchObject({ status: 422 })
      const d = await s.orders.get(order.id)
      expect(d.vendor_orders).toHaveLength(1)
      expect(d.vendor_orders[0].items[0]).toMatchObject({ product_name: 'Trail Blazer 29', quantity: 2, unit_price: 24999 })
      expect(d.payments[0]).toMatchObject({ method: 'cod', status: 'pending' })
      expect(Array.isArray(await s.orders.timeline(order.id))).toBe(true)
      expect(await fail(s.orders.get('00000000-0000-0000-0000-0000000000aa'))).toMatchObject({ kind: 'not_found' })
    })

    it('the fulfilment overview follows the vendor\'s real updates', async () => {
      const s = admin()
      const before = await s.fulfilment.list({})
      expect(before.items[0]).toMatchObject({ order_number: order.order_number, status: 'pending', vendor_name: 'Spoke & Co', delivery_city: 'Pune', payment_method: 'cod', item_count: 2 })
      const voId = before.items[0].id
      await vendorAdvance(voId)
      const after = await s.fulfilment.list({ status: 'delivered' })
      expect(after.items.map((f) => f.id)).toEqual([voId])
      expect(after.items[0].delivered_at).toBeTruthy()
      expect((await s.fulfilment.list({ status: 'pending' })).total).toBe(0)
      expect((await s.fulfilment.list({ q: 'Gear Garage' })).total).toBe(0)
      expect((await s.fulfilment.list({ vendor_id: seed.vendor_id })).total).toBe(1)
    })

    it('cash is recorded as collected only by an admin; the payment overview and report never count uncollected cash', async () => {
      const s = admin()
      const pay = (await s.payments.list({ method: 'cod' })).items[0]
      expect(pay).toMatchObject({ status: 'pending', order_number: order.order_number, customer_name: 'Asha Rao' })
      const before = await s.reports.get<{ collected: number }>('payments', '2026-01-01', '2026-12-31')
      expect(before.data.collected).toBe(0)
      expect(await fail(client('customer').post(`/admin/payments/${pay.id}/collect-cod`))).toMatchObject({ kind: 'forbidden' })
      await s.payments.collectCod(pay.id)
      expect((await s.payments.get(pay.id)).status).toBe('successful')
      expect(await fail(s.payments.collectCod(pay.id))).toMatchObject({ kind: 'conflict' })
      expect((await s.payments.list({ status: 'successful', q: order.order_number })).total).toBe(1)
      expect((await s.payments.list({ q: 'nothing-matches' })).total).toBe(0)
      expect((await s.payments.provider())).toEqual({ configured: true, provider: 'testpay', refunds_via_provider: true })
    })

    it('settlements are records with the vendor, gross, commission and net, and are filterable', async () => {
      const s = admin()
      const set = await s.settlements.list({})
      expect(set.total).toBe(1)
      expect(set.items[0]).toMatchObject({ vendor_name: 'Spoke & Co', gross_amount: 49998, commission_amount: 4999.8, status: 'ready' })
      expect(set.items[0].net_amount).toBeCloseTo(44998.2, 2)
      expect(set.summary.ready).toBeCloseTo(44998.2, 2)
      expect((await s.settlements.list({ status: 'paid' })).total).toBe(0)
      expect((await s.settlements.list({ vendor_id: seed.vendor_b_id })).total).toBe(0)
      expect((await s.settlements.list({ date_from: '2020-01-01', date_to: '2020-01-02' })).total).toBe(0)
    })

    it('refunds: validated against the paid amount, idempotent, searchable, and never marked processed without confirmation', async () => {
      const s = admin()
      const pay = (await s.payments.list({ method: 'cod' })).items[0]
      const key = newIdempotencyKey()
      expect(await fail(s.refunds.create({ payment_id: pay.id, amount: 60000, reason: 'Too much' }, newIdempotencyKey()))).toMatchObject({ kind: 'conflict' })
      expect(await fail(s.refunds.create({ payment_id: pay.id, amount: 0, reason: 'Zero' }, newIdempotencyKey()))).toMatchObject({ status: 422 })
      const r = await s.refunds.create({ payment_id: pay.id, amount: 1000, reason: 'Damaged on arrival' }, key)
      expect(r).toMatchObject({ status: 'requested', amount: 1000 })
      expect((await s.refunds.create({ payment_id: pay.id, amount: 1000, reason: 'Damaged on arrival' }, key)).id).toBe(r.id)          // same key: the same refund, not a second one
      expect((await s.refunds.list({})).total).toBe(1)
      expect((await s.refunds.list({ q: 'damaged' })).items[0].order_number).toBe(order.order_number)
      expect((await s.refunds.list({ status: 'processed' })).total).toBe(0)
      expect(await fail(s.refunds.act(r.id, { action: 'reject' }))).toMatchObject({ status: 422 })                                      // a reason is required
      expect(await fail(s.refunds.act(r.id, { action: 'process' }))).toMatchObject({ kind: 'conflict' })                                // not approved yet
      expect((await s.refunds.act(r.id, { action: 'approve' })).status).toBe('approved')
      expect(await fail(s.refunds.act(r.id, { action: 'process', manual: true }))).toMatchObject({ status: 422 })                       // manual needs the external reference
    })

    it('commission rules show scope and names, refuse ambiguous rules and tell which one applies; recorded commission is untouched', async () => {
      const s = admin()
      const rules = await s.commission.list()
      expect(rules[0]).toMatchObject({ name: 'Global', scope: 'global', state: 'active' })
      const spoke = await s.commission.create({ name: 'Spoke special', applies_to: 'product', vendor_id: seed.vendor_id, commission_type: 'percentage', commission_value: 5, priority: 1, is_active: true })
      expect(spoke).toMatchObject({ scope: 'vendor', vendor_name: 'Spoke & Co' })
      expect(await fail(s.commission.create({ name: 'Spoke clash', applies_to: 'product', vendor_id: seed.vendor_id, commission_type: 'percentage', commission_value: 6, priority: 1, is_active: true }))).toMatchObject({ kind: 'conflict', code: 'commission_rule_conflict' })
      expect(await fail(s.commission.create({ name: 'Too much', applies_to: 'product', commission_type: 'percentage', commission_value: 150, priority: 0, is_active: true }))).toMatchObject({ status: 422 })
      expect((await s.commission.resolve(seed.vendor_id, seed.category_ids.new_cycle)).rule?.name).toBe('Spoke special')
      expect((await s.commission.resolve(seed.vendor_b_id, seed.category_ids.new_cycle)).rule?.name).toBe('Global')
      await s.commission.update(spoke.id, { commission_value: 7 })
      expect((await s.settlements.list({})).items[0].commission_amount).toBe(4999.8)                                                  // the delivered order keeps its recorded commission
      await s.commission.update(spoke.id, { is_active: false })
      expect((await s.commission.history()).items.map((a) => a.action)).toContain('commission_rule_updated')
    })

    it('an order can be cancelled by an admin with a reason, which returns stock and is audited', async () => {
      const s = admin()
      const o = await placeOrder('Disc Brake Set', 1)
      expect(await fail(s.orders.cancel(o.id, ''))).toMatchObject({ status: 422 })
      const out = await s.orders.cancel(o.id, 'Customer called to cancel')
      expect(out).toMatchObject({ status: 'cancelled', cancelled_reason: 'Customer called to cancel' })
      expect(out.cancelled_by_role).toBe('admin')
      expect(await fail(s.orders.cancel(o.id, 'again please'))).toMatchObject({ kind: 'conflict' })
    })
  })

  describe('services, bookings and pickups', () => {
    let booking: BookingDetail

    it('service categories and services are administered; deactivating needs a reason and hides it from customers', async () => {
      const s = admin()
      expect((await s.serviceCategories.list()).map((c) => c.name)).toEqual(['General Servicing', 'Puncture Repair', 'Brake Repair', 'Gear Adjustment', 'Parts Replacement'])
      const c = await s.serviceCategories.create({ name: 'Wheel Truing', description: 'Straighten wheels' })
      expect(await fail(s.serviceCategories.create({ name: 'Wheel Truing' }))).toMatchObject({ kind: 'conflict' })
      expect((await s.serviceCategories.update(c.id, { is_active: false })).is_active).toBe(false)
      await s.serviceCategories.remove(c.id)
      expect(await fail(s.serviceCategories.remove(seed.service_category_id))).toMatchObject({ kind: 'conflict' })                   // a service uses it
      const list = await s.services.list({ vendor_id: seed.vendor_id, category_id: seed.service_category_id })
      expect(list.items[0]).toMatchObject({ name: 'Full service', price: 499, vendor_name: 'Spoke & Co', is_active: true })
      expect((await s.services.list({ is_available: false })).total).toBe(0)
      expect(await fail(s.services.setActive(seed.service_id, false))).toMatchObject({ status: 422 })
      expect((await s.services.setActive(seed.service_id, false, 'Misleading price')).is_active).toBe(false)
      expect(await fail(s.services.setActive(seed.service_id, false, 'once more'))).toMatchObject({ kind: 'conflict' })
      expect((await client('customer').get<{ items: unknown[] }>('/services')).items).toHaveLength(0)
      await s.services.setActive(seed.service_id, true)
    })

    it('a real booking is listed, searchable, detailed (read-only) and has a timeline', async () => {
      const cust = client('customer')
      const addr = seed.address_id
      const b = await cust.post<{ id: string }>('/service-bookings', { service_id: seed.service_id, issue_description: 'Brakes squeal and chain skips', preferred_date: seed.day, slot_start: '10:00', needs_pickup_dropoff: true, pickup_address_id: addr })
      const s = admin()
      const list = await s.bookings.list({})
      expect(list.total).toBe(1)
      expect(list.items[0]).toMatchObject({ status: 'pending', service_category: 'General Servicing', needs_pickup_dropoff: true, vendor_name: 'Spoke & Co' })
      expect((await s.bookings.list({ q: 'asha' })).total).toBe(1)
      expect((await s.bookings.list({ q: 'Spoke' })).total).toBe(1)
      expect((await s.bookings.list({ q: 'Gear Garage' })).total).toBe(0)
      expect((await s.bookings.list({ date_from: seed.day, date_to: seed.day })).total).toBe(1)
      expect((await s.bookings.list({ status: 'completed' })).total).toBe(0)
      booking = await s.bookings.get(b.id)
      expect(booking).toMatchObject({ cycle: expect.anything(), issue_description: 'Brakes squeal and chain skips' })
      expect(booking.pickup).toMatchObject({ pickup_stage: 'requested', delivery_stage: 'requested' })
      expect((await s.bookings.timeline(b.id)).map((e) => e.to_status)).toEqual(['pending'])
    })

    it('pickup coordination is separate from the booking status and follows the backend rules', async () => {
      const s = admin()
      const pk = (await s.pickups.list({})).items[0]
      expect(pk).toMatchObject({ booking_id: booking.id, booking_status: 'pending', vendor_name: 'Spoke & Co' })
      expect(await s.pickups.list({ q: 'asha' })).toMatchObject({ total: 1 })
      expect((await s.pickups.list({ pickup_status: 'scheduled' })).total).toBe(0)
      expect(await fail(s.pickups.coordinate(pk.id, { pickup_status: 'scheduled' }))).toMatchObject({ status: 422 })                    // a time is required
      const when = new Date(Date.now() + 3 * 86_400_000).toISOString()
      const out = await s.pickups.coordinate(pk.id, { scheduled_pickup_at: when, pickup_status: 'scheduled', notes: 'Call at the gate' })
      expect(out.pickup).toMatchObject({ pickup_status: 'scheduled', pickup_stage: 'scheduled', notes: 'Call at the gate', delivery_status: 'pending' })
      expect(out.booking_status).toBe('pending')                                                                                         // the booking status did not move
      expect(await fail(s.pickups.coordinate(pk.id, { pickup_status: 'completed' as never }))).toMatchObject({ status: 422 })           // completion is the vendor's booking update
    })

    it('an admin can reject a pending booking only with a reason; the vendor cannot be bypassed on acceptance', async () => {
      const s = admin()
      expect(await fail(s.bookings.setStatus(booking.id, 'accepted'))).toMatchObject({ status: 422 })
      expect(await fail(s.bookings.setStatus(booking.id, 'rejected'))).toMatchObject({ status: 422 })
      const out = await s.bookings.setStatus(booking.id, 'rejected', 'Provider cannot service this cycle')
      expect(out).toMatchObject({ status: 'rejected', rejection_reason: 'Provider cannot service this cycle' })
      expect((await s.bookings.timeline(booking.id)).at(-1)).toMatchObject({ to_status: 'rejected', changed_by_role: 'admin' })
    })
  })

  describe('notifications and announcements', () => {
    it('an announcement reaches the targeted active users as in-app notifications, with history and read counts', async () => {
      const s = admin()
      const sent = await s.communication.send({ title: 'Festive sale', message: 'Up to 20% off cycles.', type: 'promotion', audience: 'customers' })
      expect(sent).toMatchObject({ recipient_count: 2, delivered: 2, read: 0, audience: 'customers', type: 'promotion', channel: 'in_app', created_by_name: expect.anything() })
      const mine = await client('customer').get<{ items: { id: string; title: string; type: string }[]; unread_count: number }>('/notifications')
      expect(mine.items.some((x) => x.title === 'Festive sale' && x.type === 'promotion')).toBe(true)
      await client('customer').post(`/notifications/${mine.items.find((x) => x.title === 'Festive sale')!.id}/read`)
      expect((await s.communication.announcements({})).items[0]).toMatchObject({ read: 1, delivered: 2 })
      expect((await client('vendor_user').get<{ items: { title: string }[] }>('/notifications')).items.some((x) => x.title === 'Festive sale')).toBe(false)
      expect((await s.communication.records({ announcement_id: sent.id })).total).toBe(2)
      expect((await s.communication.records({ type: 'promotion', q: 'asha' })).total).toBe(1)
    })

    it('push delivery is reported honestly: no provider configured means nothing is claimed or sent, and the in-app notification still exists', async () => {
      const s = admin()
      const status = await s.communication.pushStatus()
      expect(status).toMatchObject({ configured: false, provider: null, dispatcher_enabled: false })
      expect(JSON.stringify(status)).not.toMatch(/token|private_key|secret/i)
      expect(await s.communication.dispatchPush()).toEqual({ configured: false, claimed: 0, sent: 0, retry: 0, failed: 0, skipped: 0 })
      const sent = await s.communication.send({ title: 'Push check', message: 'Is push configured?', type: 'announcement', audience: 'customers' })
      expect(sent).toMatchObject({ delivered: 2, push_sent: 0, push_failed: 0, push_pending: 2 })          // waiting, never reported as sent
      const rec = await s.communication.records({ announcement_id: sent.id })
      expect(rec.items.every((n) => n.push_status === 'pending')).toBe(true)
      // a customer registers a phone; the vendor-only and admin accounts cannot use the customer registration
      const cust = client('customer')
      expect(await cust.put('/devices', { token: 'contract-admin-device-token-0001', platform: 'android', app: 'customer' })).toEqual({ registered: true })
      expect((await s.communication.pushStatus()).active_devices).toEqual({ customer: 1 })
      expect(await fail(client('vendor_user').put('/devices', { token: 'contract-admin-device-token-0002', platform: 'android', app: 'customer' }))).toMatchObject({ kind: 'forbidden' })
      await cust.post('/devices/unregister', { token: 'contract-admin-device-token-0001' })
      expect((await s.communication.pushStatus()).active_devices).toEqual({})
    })

    it('audiences are validated; admins and unknown ids are never recipients; a send with nobody to notify changes nothing', async () => {
      const s = admin()
      expect(await fail(s.communication.send({ title: 'Hi there', message: 'Hello', type: 'announcement', audience: 'specific', user_ids: [seed.admin] }))).toMatchObject({ status: 422 })
      expect(await fail(s.communication.send({ title: 'Hi there', message: 'Hello', type: 'announcement', audience: 'specific' }))).toMatchObject({ status: 422 })
      expect(await fail(s.communication.send({ title: 'x', message: 'Hello', type: 'announcement', audience: 'customers' }))).toMatchObject({ status: 422 })
      const one = await s.communication.send({ title: 'Just you', message: 'A personal note', type: 'announcement', audience: 'specific', user_ids: [seed.vendor_user] })
      expect(one.recipient_count).toBe(1)
      const before = (await s.communication.announcements({})).total
      await client('admin').patch(`/admin/customers/${seed.customer}/status`, { status: 'inactive', reason: 'testing no-recipient case' })
      await client('admin').patch(`/admin/customers/${seed.other}/status`, { status: 'inactive', reason: 'testing no-recipient case' })
      expect(await fail(s.communication.send({ title: 'Nobody', message: 'Nobody home', type: 'announcement', audience: 'customers' }))).toMatchObject({ kind: 'conflict', code: 'no_recipients' })
      expect((await s.communication.announcements({})).total).toBe(before)
      await client('admin').patch(`/admin/customers/${seed.customer}/status`, { status: 'active' })
      await client('admin').patch(`/admin/customers/${seed.other}/status`, { status: 'active' })
    })
  })

  describe('coupons', () => {
    it('create, search, edit, deactivate; the code is unique, validated, and cannot change after use', async () => {
      const s = admin()
      const c = await s.coupons.create({ code: 'summer15', discount_type: 'percentage', discount_value: 15, max_discount_amount: 300, min_order_amount: 999, usage_limit: 50, per_user_limit: 2 })
      expect(c).toMatchObject({ code: 'SUMMER15', state: 'active', used_count: 0, applies_to: 'all' })
      expect(await fail(s.coupons.create({ code: 'Summer15', discount_type: 'fixed', discount_value: 10 }))).toMatchObject({ kind: 'conflict' })
      for (const bad of [{ code: 'x' }, { discount_value: 150 }, { discount_value: 0 }, { applies_to: 'services' }, { valid_from: '2030-01-02T00:00:00Z', valid_until: '2030-01-01T00:00:00Z' }]) {
        expect(await fail(s.coupons.create({ code: 'GOODCODE', discount_type: 'percentage', discount_value: 10, ...bad } as never)), JSON.stringify(bad)).toMatchObject({ status: 422 })
      }
      expect((await s.coupons.list({ q: 'summer' })).items.map((x) => x.code)).toEqual(['SUMMER15'])
      expect((await s.coupons.update(c.id, { discount_value: 20 })).discount_value).toBe(20)
      expect((await s.coupons.update(c.id, { is_active: false })).state).toBe('inactive')
      expect((await s.coupons.list({ is_active: false })).total).toBe(1)
      // a customer redeems the seeded coupon at the real checkout; the counter moves and the code is then locked
      const welcome = (await s.coupons.list({ q: 'WELCOME10' })).items[0]
      expect(welcome.used_count).toBe(0)
      await placeOrder('Old Commuter', 1, { coupon_code: 'WELCOME10' })
      const used = (await s.coupons.list({ q: 'WELCOME10' })).items[0]
      expect(used.used_count).toBe(1)
      expect(await fail(s.coupons.update(welcome.id, { code: 'RENAMED' }))).toMatchObject({ kind: 'conflict', code: 'coupon_code_locked' })
      expect(await fail(s.coupons.update(welcome.id, { usage_limit: 1, discount_value: 0 }))).toMatchObject({ status: 422 })
      expect((await s.coupons.update(welcome.id, { usage_limit: 1 })).state).toBe('exhausted')
    })
  })

  describe('platform settings and the audit trail', () => {
    it('settings are validated by the backend and every change is audited', async () => {
      const s = admin()
      const all = await s.settings.list()
      expect(all.map((x) => x.key)).toContain('services.pickup_charge')
      expect(all.find((x) => x.key === 'services.pickup_charge')).toMatchObject({ configured: false })
      expect((await s.settings.put('services.pickup_charge', 75.5)).value).toBe(75.5)
      expect((await s.settings.put('checkout.delivery_charge', { amount: 60, free_above: 1500, per: 'vendor_order' })).value).toEqual({ amount: 60, free_above: 1500, per: 'vendor_order' })
      expect(await fail(s.settings.put('services.pickup_charge', -5))).toMatchObject({ status: 422 })
      expect(await fail(s.settings.put('checkout.delivery_charge', { amount: 'lots' }))).toMatchObject({ status: 422 })
      expect(await fail(s.settings.put('payments.secret_key', 'x'))).toMatchObject({ status: 422 })                                      // unknown settings cannot be invented
      expect(await fail(s.settings.put('payments.cod_enabled', 'yes'))).toMatchObject({ status: 422 })
      const h = await s.settings.history()
      expect(h.items.filter((a) => a.action === 'setting_changed').length).toBeGreaterThanOrEqual(2)
      expect(h.items[0]).toMatchObject({ actor_role: 'admin' })
    })
  })

  describe('reports', () => {
    it('every report returns real figures for the period, validates the period, and shows empty periods as zeros', async () => {
      const s = admin()
      const from = '2026-01-01'
      const to = '2026-12-31'
      const orders = await s.reports.get<{ total: number; by_status: Record<string, number>; series: unknown[] }>('orders', from, to)
      expect(orders).toMatchObject({ kind: 'orders', timezone: 'Asia/Kolkata', period_from: from, period_to: to })
      expect(orders.data.total).toBeGreaterThanOrEqual(2)
      const sales = await s.reports.get<{ delivered_orders: number; gross_sales: number; by_vendor: { vendor_name: string }[]; by_product: { product_name: string }[] }>('sales', from, to)
      expect(sales.data).toMatchObject({ delivered_orders: 1, gross_sales: 49998 })
      expect(sales.data.by_vendor[0].vendor_name).toBe('Spoke & Co')
      expect(sales.data.by_product[0].product_name).toBe('Trail Blazer 29')
      expect((await s.reports.get<{ collected: number }>('payments', from, to)).data.collected).toBe(49998)
      expect((await s.reports.get<{ performance: unknown[] }>('vendors', from, to)).data.performance.length).toBeGreaterThan(0)
      expect((await s.reports.get<{ total: number }>('customers', from, to)).data.total).toBe(2)
      expect((await s.reports.get<{ total: number; by_status: Record<string, number> }>('services', from, to)).data).toMatchObject({ total: 1, by_status: { rejected: 1 } })
      const empty = await s.reports.get<{ total: number; series: { count: number }[] }>('orders', '2030-01-01', '2030-01-03')
      expect(empty.data.total).toBe(0)
      expect(empty.data.series).toHaveLength(3)
      expect(await fail(s.reports.get('orders', '2026-02-01', '2026-01-01'))).toMatchObject({ status: 422 })
      expect(await fail(s.reports.get('orders', '2020-01-01', '2026-01-01'))).toMatchObject({ status: 422 })
      expect(await fail(s.reports.get('nonsense' as never, from, to))).toMatchObject({ status: 422 })
    })
  })
})
