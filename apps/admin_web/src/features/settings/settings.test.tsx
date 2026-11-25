import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { audit, coupon, setting } from '../../test/factories'
import { baseRoutes, err, fakeGateway, page, renderApp } from '../../test/utils'

const allSettings = (over: Record<string, unknown> = {}) => {
  const base: Record<string, unknown> = { 'payments.cod_enabled': true, 'payments.online_enabled': false, 'checkout.multi_vendor_policy': null, 'checkout.delivery_charge': null, 'commission.missing_rule_policy': 'block', 'checkout.payment_window_minutes': 30,
    'marketplace.require_listing_approval': true, 'services.pickup_charge': null, 'services.dropoff_charge': null, 'services.min_notice_hours': 2, 'services.max_advance_days': 60, ...over }
  return Object.entries(base).map(([k, v]) => setting(k, v, { configured: v !== null, description: `Meaning of ${k}`, default_behaviour: `default for ${k}` }))
}
const routes = (over: Record<string, unknown> = {}, settings = allSettings()) => ({ ...baseRoutes(), 'GET /admin/settings': { body: settings }, 'PUT /admin/settings/:key': (c: { path: string; body: { value: unknown } }) => ({ body: setting(c.path.split('/').at(-1)!, c.body.value) }),
  'GET /admin/payments/provider': { body: { configured: false, provider: null, refunds_via_provider: false } }, 'GET /admin/audit-log': { body: page([audit({ action: 'setting_changed', entity_type: 'setting', details: { key: 'payments.cod_enabled', to: false } })]) }, ...over })
const open = (r: Record<string, unknown>, path: string) => renderApp({ path, gateway: fakeGateway({ token: 'tok' }), routes: r as never })
const section = async (name: string) => (await screen.findByRole('region', { name })) as HTMLElement

describe('platform settings', () => {
  it('shows only settings the backend supports, with what each means and what happens while unset', async () => {
    open(routes(), '/settings')
    expect(await screen.findByRole('heading', { name: 'Platform settings' })).toBeInTheDocument()
    const multi = await section('Multi-vendor checkout')
    expect(within(multi).getByText(/Not set yet/)).toBeInTheDocument()
    expect(within(multi).getByText(/default for checkout.multi_vendor_policy/)).toBeInTheDocument()
    expect(screen.getByText(/open client decision/)).toBeInTheDocument()
    expect(screen.getByText(/never sent to or shown in this console/)).toBeInTheDocument()
    expect(screen.getByText('Not configured')).toBeInTheDocument()
    expect(await screen.findByText('Setting changed')).toBeInTheDocument()
  })

  it('turning cash on delivery off asks first and saves the real boolean', async () => {
    const { backend } = open(routes(), '/settings')
    const cod = await section('Cash on delivery')
    const save = within(cod).getByRole('button', { name: /Save cash on delivery/ })
    expect(save).toBeDisabled()                                                          // nothing changed yet
    await userEvent.click(within(cod).getByRole('checkbox'))
    await userEvent.click(save)
    const dialog = await screen.findByRole('dialog')
    expect(backend.count('PUT', '/admin/settings/payments.cod_enabled')).toBe(0)
    await userEvent.click(within(dialog).getByRole('button', { name: 'Turn off' }))
    await waitFor(() => expect(backend.count('PUT', '/admin/settings/payments.cod_enabled')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ value: false })
  })

  it('turning online payments on needs no confirmation', async () => {
    const { backend } = open(routes(), '/settings')
    const online = await section('Online payments')
    await userEvent.click(within(online).getByRole('checkbox'))
    await userEvent.click(within(online).getByRole('button', { name: /Save online payments/ }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ value: true }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('numbers are validated before they are sent and the backend\'s own refusal is shown', async () => {
    const { backend } = open(routes({ 'PUT /admin/settings/services.max_advance_days': err(422, 'invalid_setting', 'services.max_advance_days: must be a whole number between 1 and 365') }), '/settings')
    const window = await section('Payment window')
    const input = within(window).getByLabelText(/Minutes to complete/)
    await userEvent.clear(input)
    await userEvent.type(input, '3')
    await userEvent.click(within(window).getByRole('button', { name: /Save payment window/ }))
    expect(within(window).getByText('Enter a whole number between 5 and 1440.')).toBeInTheDocument()
    expect(backend.count('PUT', '/admin/settings/checkout.payment_window_minutes')).toBe(0)
    await userEvent.clear(input)
    await userEvent.type(input, '45')
    await userEvent.click(within(window).getByRole('button', { name: /Save payment window/ }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ value: 45 }))
    const booking = await section('Booking window')
    await userEvent.clear(within(booking).getByLabelText(/How far ahead/))
    await userEvent.type(within(booking).getByLabelText(/How far ahead/), '90')
    await userEvent.click(within(booking).getByRole('button', { name: /Save booking window/ }))
    expect(await within(booking).findByRole('alert')).toHaveTextContent('must be a whole number between 1 and 365')
  })

  it('choice settings save the selected value', async () => {
    const { backend } = open(routes(), '/settings')
    const policy = await section('When no commission rule matches')
    await userEvent.selectOptions(within(policy).getByLabelText('Checkout behaviour'), 'zero')
    await userEvent.click(within(policy).getByRole('button', { name: /Save when no commission rule matches/ }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ value: 'zero' }))
  })
})

describe('pickup and delivery charges', () => {
  it('delivery charge: validates, then saves amount, free-above threshold and how it is charged', async () => {
    const { backend } = open(routes(), '/settings/charges')
    const delivery = await section('Delivery charge')
    expect(within(delivery).getByText(/Not set yet/)).toBeInTheDocument()
    await userEvent.type(within(delivery).getByLabelText(/Charge \(₹\)/), '-5')
    await userEvent.click(within(delivery).getByRole('button', { name: /Save delivery charge/ }))
    expect(within(delivery).getByText(/Enter an amount between ₹0 and ₹100000/)).toBeInTheDocument()
    expect(backend.count('PUT', '/admin/settings/checkout.delivery_charge')).toBe(0)
    await userEvent.clear(within(delivery).getByLabelText(/Charge \(₹\)/))
    await userEvent.type(within(delivery).getByLabelText(/Charge \(₹\)/), '60')
    await userEvent.type(within(delivery).getByLabelText(/Free delivery above/), '1500')
    await userEvent.selectOptions(within(delivery).getByLabelText('Charged'), 'vendor_order')
    await userEvent.click(within(delivery).getByRole('button', { name: /Save delivery charge/ }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ value: { amount: 60, free_above: 1500, per: 'vendor_order' } }))
  })

  it('pickup and drop-off charges are separate money settings; nothing is pre-filled', async () => {
    const { backend } = open(routes(), '/settings/charges')
    const pickup = await section('Pickup charge')
    expect(within(pickup).getByLabelText(/Charge for collecting the cycle/)).toHaveValue('')
    await userEvent.type(within(pickup).getByLabelText(/Charge for collecting the cycle/), '75.50')
    await userEvent.click(within(pickup).getByRole('button', { name: /Save pickup charge/ }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PUT')!.path).toBe('/admin/settings/services.pickup_charge'))
    expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ value: 75.5 })
    const drop = await section('Drop-off charge')
    await userEvent.type(within(drop).getByLabelText(/Charge for returning the cycle/), '80.999')
    await userEvent.click(within(drop).getByRole('button', { name: /Save drop-off charge/ }))
    expect(within(drop).getByText(/two decimals at most/)).toBeInTheDocument()
  })
})

describe('offers and coupons', () => {
  const list = () => ({ 'GET /admin/coupons': { body: page([coupon(1, { code: 'WELCOME10', used_count: 3 }), coupon(2, { code: 'FLAT100', discount_type: 'fixed', discount_value: 100, max_discount_amount: null, usage_limit: null, per_user_limit: null, is_active: false, state: 'inactive' }), coupon(3, { code: 'OLD', state: 'expired', valid_until: '2026-01-01T00:00:00Z' })]) } })
  const rowOf = async (t: string) => (await screen.findByText(t)).closest('tr') as HTMLElement

  it('lists code, discount, minimum, validity, usage and status', async () => {
    const { backend } = open({ ...baseRoutes(), ...list() }, '/settings/coupons')
    const row = await rowOf('WELCOME10')
    expect(within(row).getByText('10% off (max ₹200)')).toBeInTheDocument()
    expect(within(row).getByText('₹500')).toBeInTheDocument()
    expect(within(row).getByText(/3 \/ 100/)).toBeInTheDocument()
    expect(within(row).getByText(/1 per customer/)).toBeInTheDocument()
    expect(within(row).getByText('Active')).toBeInTheDocument()
    expect(within(await rowOf('FLAT100')).getByText('₹100 off')).toBeInTheDocument()
    expect(within(await rowOf('OLD')).getByText('Expired')).toBeInTheDocument()
    expect(screen.getByText(/does not keep a separate list of redemptions/)).toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Active'), 'false')
    await userEvent.type(screen.getByPlaceholderText(/Search code/), 'flat')
    await waitFor(() => { const q = backend.calls.filter((c) => c.path === '/admin/coupons').at(-1)!.query; expect([q.get('is_active'), q.get('q')]).toEqual(['false', 'flat']) })
  })

  it('validates the code, the discount, the dates and the limits before sending', async () => {
    const { backend } = open({ ...baseRoutes(), ...list(), 'POST /admin/coupons': { body: coupon(9) } }, '/settings/coupons')
    await screen.findByText('WELCOME10')
    await userEvent.click(screen.getByRole('button', { name: 'New coupon' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Coupon code/), 'bad code')
    await userEvent.type(within(dialog).getByLabelText(/Percentage/), '150')
    await userEvent.type(within(dialog).getByLabelText('Valid from'), '2026-05-02T10:00')
    await userEvent.type(within(dialog).getByLabelText('Valid until'), '2026-05-01T10:00')
    await userEvent.type(within(dialog).getByLabelText(/Total redemptions/), '0')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    for (const msg of ['Use 3–30 letters, numbers, - or _ (no spaces).', 'A percentage cannot exceed 100.', 'The end must be after the start.', 'Enter a whole number above zero, or leave empty.']) expect(within(dialog).getByText(msg)).toBeInTheDocument()
    expect(backend.count('POST', '/admin/coupons')).toBe(0)
  })

  it('creates a coupon with exactly the supported fields; a duplicate code is reported by the backend', async () => {
    let n = 0
    const { backend } = open({ ...baseRoutes(), ...list(), 'POST /admin/coupons': () => (++n === 1 ? err(409, 'coupon_code_taken', 'A coupon with this code already exists.') : { body: coupon(9) }) }, '/settings/coupons')
    await screen.findByText('WELCOME10')
    await userEvent.click(screen.getByRole('button', { name: 'New coupon' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Coupon code/), 'summer15')
    await userEvent.type(within(dialog).getByLabelText(/Percentage/), '15')
    await userEvent.type(within(dialog).getByLabelText(/Maximum discount/), '300')
    await userEvent.clear(within(dialog).getByLabelText(/Minimum order/))
    await userEvent.type(within(dialog).getByLabelText(/Minimum order/), '999')
    await userEvent.type(within(dialog).getByLabelText(/Per customer limit/), '2')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('already exists')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(backend.count('POST', '/admin/coupons')).toBe(2))
    expect(backend.calls.find((c) => c.method === 'POST')!.body).toEqual({ code: 'summer15', discount_type: 'percentage', discount_value: 15, max_discount_amount: 300, min_order_amount: 999, applies_to: 'products', per_user_limit: 2, is_active: true })
  })

  it('a coupon that was already used cannot change its code, and cannot go below its redemptions', async () => {
    const { backend } = open({ ...baseRoutes(), ...list(), 'PUT /admin/coupons/cp-1': { body: coupon(1) } }, '/settings/coupons')
    await userEvent.click(within(await rowOf('WELCOME10')).getByRole('button', { name: 'Edit' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByLabelText(/Coupon code/)).toBeDisabled()
    await userEvent.clear(within(dialog).getByLabelText(/Total redemptions/))
    await userEvent.type(within(dialog).getByLabelText(/Total redemptions/), '2')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(within(dialog).getByText(/Already redeemed 3 time/)).toBeInTheDocument()
    await userEvent.clear(within(dialog).getByLabelText(/Total redemptions/))
    await userEvent.type(within(dialog).getByLabelText(/Total redemptions/), '50')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(backend.count('PUT', '/admin/coupons/cp-1')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'PUT')!.body).not.toHaveProperty('code')
    expect(backend.calls.find((c) => c.method === 'PUT')!.body).toMatchObject({ usage_limit: 50 })
  })

  it('activating and deactivating asks first', async () => {
    const { backend } = open({ ...baseRoutes(), ...list(), 'PUT /admin/coupons/cp-2': { body: coupon(2) } }, '/settings/coupons')
    await userEvent.click(within(await rowOf('FLAT100')).getByRole('button', { name: 'Activate' }))
    const dialog = await screen.findByRole('dialog')
    expect(backend.count('PUT', '/admin/coupons/cp-2')).toBe(0)
    await userEvent.click(within(dialog).getByRole('button', { name: 'Activate' }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ is_active: true }))
  })
})
