import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { audit, category, payment, refund, rule, settlement } from '../../test/factories'
import { baseRoutes, err, fakeGateway, page, renderApp, vendor } from '../../test/utils'

const provider = (configured = true) => ({ 'GET /admin/payments/provider': { body: { configured, provider: configured ? 'testpay' : null, refunds_via_provider: configured } } })
const common = () => ({ ...baseRoutes(), ...provider(), 'GET /admin/vendors': { body: page([vendor(1, { business_name: 'Alpha Cycles', verification_status: 'approved' })]) }, 'GET /admin/categories': { body: [category(1)] }, 'GET /admin/service-categories': { body: [] } })
const open = (routes: Record<string, unknown>, path: string) => renderApp({ path, gateway: fakeGateway({ token: 'tok' }), routes: { ...common(), ...routes } as never })
const rowOf = async (text: string | RegExp) => (await screen.findByText(text)).closest('tr') as HTMLElement

const paymentsReport = { body: { kind: 'payments', period_from: '2026-03-01', period_to: '2026-03-30', timezone: 'Asia/Kolkata', data: { total: 6, by_status: { pending: { count: 2, amount: 1500 }, processing: { count: 1, amount: 500 }, failed: { count: 1, amount: 700 }, successful: { count: 2, amount: 9000 } },
  by_method: {}, collected: 12000, collected_by_method: { online: { count: 2, amount: 9000 }, cod: { count: 1, amount: 3000 } }, refunded: 800, refunds_by_status: {}, commission: 1200, series: [] } } }
const summary = { body: { period_from: '2026-03-01T00:00:00Z', period_to: '2026-03-30T00:00:00Z', collected: 12000, refunded: 800, net_collected: 11200, commission_earned: 1200, cod_outstanding: 4500, orders_placed: 9, orders_completed: 5, settlements: {} } }

describe('payments', () => {
  const list = () => ({ 'GET /admin/payments': { body: page([payment(1), payment(2, { method: 'cod', status: 'pending', provider_order_id: null, provider_payment_id: null, paid_at: null, amount: 3000 })]) }, 'GET /admin/reports/payments': paymentsReport, 'GET /admin/payments/summary': summary })

  it('shows real overview figures: online and cash collected separately, pending, failed, refunded, commission', async () => {
    open(list(), '/payments')
    const online = (await screen.findByText('Online collected')).closest('.metric') as HTMLElement
    await waitFor(() => expect(within(online).getByText('₹9,000')).toBeInTheDocument())
    expect(within((screen.getByText('Cash on delivery collected')).closest('.metric') as HTMLElement).getByText('₹3,000')).toBeInTheDocument()
    expect(within((screen.getByText('COD still to collect')).closest('.metric') as HTMLElement).getByText('₹4,500')).toBeInTheDocument()
    expect(within((screen.getByText('Pending payments')).closest('.metric') as HTMLElement).getByText('3')).toBeInTheDocument()      // pending + processing
    expect(within((screen.getByText('Failed payments')).closest('.metric') as HTMLElement).getByText('1')).toBeInTheDocument()
    expect(within((screen.getByText('Refunded (processed)')).closest('.metric') as HTMLElement).getByText('₹800')).toBeInTheDocument()
    expect(within((screen.getByText('Platform commission')).closest('.metric') as HTMLElement).getByText('₹1,200')).toBeInTheDocument()
    expect(screen.getByText(/never counted as collected/)).toBeInTheDocument()
  })

  it('lists transactions with order, customer, method, amount, status and provider reference; filters reach the backend', async () => {
    const { backend } = open(list(), '/payments')
    const row = await rowOf('po_1')
    expect(within(row).getByRole('link', { name: 'ORD-0001' })).toHaveAttribute('href', '/orders/o-1')
    expect(within(row).getByText('Asha Rao')).toBeInTheDocument()
    expect(within(row).getByText('Online')).toBeInTheDocument()
    expect(within(row).getByText('₹1,000')).toBeInTheDocument()
    expect(within(row).getByText('Successful')).toBeInTheDocument()
    expect(within(row).getByText('pp_1')).toBeInTheDocument()
    expect(within(await rowOf('ORD-0002')).getByText('Cash on delivery')).toBeInTheDocument()
    const status = screen.getByLabelText('Status') as HTMLSelectElement
    expect([...status.options].map((o) => o.value)).toEqual(['', 'pending', 'processing', 'successful', 'failed', 'cancelled', 'refunded', 'partially_refunded'])
    await userEvent.selectOptions(status, 'failed')
    await userEvent.selectOptions(screen.getByLabelText('Method'), 'cod')
    await userEvent.type(screen.getByLabelText('From'), '2026-03-01')
    await userEvent.type(screen.getByPlaceholderText(/Search transaction/), 'po_1')
    await waitFor(() => { const q = backend.calls.filter((c) => c.path === '/admin/payments').at(-1)!.query; expect([q.get('status'), q.get('method'), q.get('date_from'), q.get('q')]).toEqual(['failed', 'cod', '2026-03-01', 'po_1']) })
  })

  const detail = (p: Record<string, unknown>) => ({ [`GET /admin/payments/${p.id}`]: { body: { ...p, order: { id: 'o-1', order_number: 'ORD-0001', status: 'confirmed', payment_status: 'successful', total_amount: 1000 }, events: [{ id: 'e1', event_type: 'payment.succeeded', outcome: 'applied', amount: 1000, created_at: '2026-03-10T10:00:00Z' }], refunds: [] } } })

  it('a cash payment can be recorded as collected only after an explicit confirmation', async () => {
    const { backend } = open({ ...detail(payment(2, { method: 'cod', status: 'pending', amount: 3000, paid_at: null })), 'POST /admin/payments/pay-2/collect-cod': { body: {} } }, '/payments/pay-2')
    await userEvent.click(await screen.findByRole('button', { name: 'Record cash collected' }))
    const dialog = await screen.findByRole('dialog')
    expect(backend.count('POST', '/admin/payments/pay-2/collect-cod')).toBe(0)
    expect(within(dialog).getByText(/cannot be undone/)).toBeInTheDocument()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Record collection' }))
    await waitFor(() => expect(backend.count('POST', '/admin/payments/pay-2/collect-cod')).toBe(1))
  })

  it('shows provider events and never any credential or card data', async () => {
    open(detail(payment(1)), '/payments/pay-1')
    expect(await screen.findByText('payment.succeeded')).toBeInTheDocument()
    expect(screen.getByText('pp_1')).toBeInTheDocument()
    expect(document.body.textContent).not.toMatch(/secret|card number|cvv|api[_ ]key/i)
  })

  it('a refund cannot exceed what was paid; the same idempotency key is reused on a retry so it cannot be created twice', async () => {
    let attempts = 0
    const { backend } = open({ ...detail(payment(1, { refunded_amount: 200 })), 'POST /admin/refunds': () => { attempts++; return attempts === 1 ? err(409, 'refund_exceeds', 'The refund would exceed the amount paid.') : { body: refund(1) } } }, '/payments/pay-1')
    await userEvent.click(await screen.findByRole('button', { name: 'Request refund' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Amount/), '900')
    await userEvent.type(within(dialog).getByLabelText(/Reason/), 'Damaged on arrival')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Request refund' }))
    expect(await within(dialog).findByText('The most that can be refunded is ₹800.')).toBeInTheDocument()
    expect(backend.count('POST', '/admin/refunds')).toBe(0)
    await userEvent.clear(within(dialog).getByLabelText(/Amount/))
    await userEvent.type(within(dialog).getByLabelText(/Amount/), '500')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Request refund' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('would exceed the amount paid')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Request refund' }))
    await waitFor(() => expect(backend.count('POST', '/admin/refunds')).toBe(2))
    const [first, second] = backend.calls.filter((c) => c.path === '/admin/refunds')
    expect(first.body).toEqual({ payment_id: 'pay-1', amount: 500, reason: 'Damaged on arrival' })
    expect(first.headers['Idempotency-Key']).toBeTruthy()
    expect(second.headers['Idempotency-Key']).toBe(first.headers['Idempotency-Key'])
  })

  it('without a payment provider, checking with the provider is unavailable and the page says so', async () => {
    open({ ...detail(payment(1, { status: 'pending', paid_at: null })), ...provider(false) }, '/payments/pay-1')
    expect(await screen.findByText(/No online payment provider is configured/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Check with provider' })).toBeDisabled()
  })

  it('a fully refunded payment cannot be refunded again', async () => {
    open(detail(payment(1, { status: 'refunded', refunded_amount: 1000 })), '/payments/pay-1')
    await screen.findByText('payment.succeeded')
    expect(screen.queryByRole('button', { name: 'Request refund' })).not.toBeInTheDocument()
  })
})

describe('refunds', () => {
  const list = () => ({ 'GET /admin/refunds': { body: page([refund(1), refund(2, { status: 'approved' }), refund(3, { status: 'processed', provider_refund_id: 'rf_ext1', processed_at: '2026-03-12T10:00:00Z' }), refund(4, { status: 'failed', failure_reason: 'Provider declined' })]) } })

  it('shows each refund with order, payment, amount, reason, provider reference and status, and the right actions per state', async () => {
    open(list(), '/refunds')
    const requested = await rowOf('ORD-0001')
    expect(within(requested).getByText('₹300')).toBeInTheDocument()
    expect(within(requested).getByText('Damaged item')).toBeInTheDocument()
    expect(within(requested).getByRole('button', { name: 'Approve' })).toBeInTheDocument()
    expect(within(requested).getByRole('button', { name: 'Reject' })).toBeInTheDocument()
    expect(within(requested).queryByRole('button', { name: 'Process' })).not.toBeInTheDocument()
    const approved = await rowOf('ORD-0002')
    expect(within(approved).getByRole('button', { name: 'Process' })).toBeInTheDocument()
    expect(within(approved).getByRole('button', { name: 'Mark failed' })).toBeInTheDocument()
    const done = await rowOf('ORD-0003')
    expect(within(done).getByText('rf_ext1')).toBeInTheDocument()
    expect(within(done).queryByRole('button')).toBeNull()                                  // processed refunds are history
    const failed = await rowOf('ORD-0004')
    expect(within(failed).getByText('Provider declined')).toBeInTheDocument()
    expect(within(failed).getByRole('button', { name: 'Retry (approve)' })).toBeInTheDocument()
  })

  it('the status tabs, search and dates reach the backend', async () => {
    const { backend } = open(list(), '/refunds')
    await screen.findByText('ORD-0001')
    await userEvent.click(screen.getByRole('tab', { name: 'Processed' }))
    await userEvent.type(screen.getByPlaceholderText(/Search order number/), 'damaged')
    await userEvent.type(screen.getByLabelText('To'), '2026-03-31')
    await waitFor(() => { const q = backend.calls.filter((c) => c.path === '/admin/refunds').at(-1)!.query; expect([q.get('status'), q.get('q'), q.get('date_to')]).toEqual(['processed', 'damaged', '2026-03-31']) })
  })

  it('without a provider a refund cannot be processed through one; a manual record needs the external reference and is sent as manual', async () => {
    open({ ...list(), ...provider(false), 'POST /admin/refunds/rf-2000000/actions': { body: refund(2, { status: 'processed' }) } }, '/refunds')
    await userEvent.click(within(await rowOf('ORD-0002')).getByRole('button', { name: 'Process' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText(/No payment provider is configured/)).toBeInTheDocument()
    const go = within(dialog).getByRole('button', { name: 'Process' })
    expect(go).toBeDisabled()
    await userEvent.click(within(dialog).getByLabelText(/already paid outside the system/))
    expect(go).toBeDisabled()                                                              // reference still missing
    await userEvent.type(within(dialog).getByLabelText(/External payment reference/), 'NEFT-998877')
    expect(go).toBeEnabled()
  })

  it('processing through a configured provider sends a provider refund; rejecting needs a reason', async () => {
    const { backend } = open({ ...list(), 'POST /admin/refunds/:id/actions': { body: refund(2, { status: 'approved', provider_refund_id: 'rf_pending' }) } }, '/refunds')
    await userEvent.click(within(await rowOf('ORD-0002')).getByRole('button', { name: 'Process' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Process' }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'POST')!.body).toEqual({ action: 'process', manual: false }))
    await userEvent.click(within(await rowOf('ORD-0001')).getByRole('button', { name: 'Reject' }))
    const dialog = (await screen.findAllByRole('dialog')).at(-1)!
    expect(within(dialog).getByRole('button', { name: 'Reject' })).toBeDisabled()
    await userEvent.type(within(dialog).getByRole('textbox'), 'Outside the return window')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Reject' }))
    await waitFor(() => expect(backend.calls.filter((c) => c.method === 'POST').at(-1)!.body).toEqual({ action: 'reject', note: 'Outside the return window' }))
  })
})

describe('commission management', () => {
  const rules = () => ({ 'GET /admin/commission-rules': { body: [rule(1, { name: 'Global', is_active: true }), rule(2, { name: 'Alpha special', scope: 'vendor', vendor_id: 'v-1', vendor_name: 'Alpha Cycles', commission_value: 5, priority: 2 }),
    rule(3, { name: 'Old promo', state: 'inactive', is_active: false, commission_type: 'fixed', commission_value: 40 })] }, 'GET /admin/audit-log': { body: page([audit({ action: 'commission_rule_updated', entity_type: 'commission_rule', details: { commission_value: 12 } })]) }, 'GET /admin/payments/summary': summary })

  it('lists each rule with what it covers, its rate, priority, dates and state, plus real commission earned and the change history', async () => {
    open(rules(), '/commission')
    const alpha = await rowOf('Alpha special')
    expect(within(alpha).getByText('One vendor')).toBeInTheDocument()
    expect(within(alpha).getByText('Alpha Cycles')).toBeInTheDocument()
    expect(within(alpha).getByText('5%')).toBeInTheDocument()
    expect(within(await rowOf('Old promo')).getByText('₹40 per unit')).toBeInTheDocument()
    expect(within(await rowOf('Old promo')).getByText('Inactive')).toBeInTheDocument()
    expect(within((await screen.findByText('Commission earned (last 30 days)')).closest('.metric') as HTMLElement).getByText('₹1,200')).toBeInTheDocument()
    expect(await screen.findByText('Commission rule updated')).toBeInTheDocument()
    expect(screen.getByText(/past records never change/)).toBeInTheDocument()
  })

  it('validates values before anything is sent: percentages above 100, empty and negative values are refused', async () => {
    const { backend } = open({ ...rules(), 'POST /admin/commission-rules': { body: rule(9) } }, '/commission')
    await screen.findByText('Alpha special')
    await userEvent.click(screen.getByRole('button', { name: 'New rule' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Rule name/), 'Cycles 12')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(within(dialog).getByText('Enter a value of 0 or more.')).toBeInTheDocument()
    await userEvent.type(within(dialog).getByLabelText(/Percentage/), '120')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(within(dialog).getByText('A percentage cannot exceed 100.')).toBeInTheDocument()
    await userEvent.clear(within(dialog).getByLabelText(/Percentage/))
    await userEvent.type(within(dialog).getByLabelText(/Percentage/), '-3')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(within(dialog).getByText('Enter a value of 0 or more.')).toBeInTheDocument()
    expect(backend.count('POST', '/admin/commission-rules')).toBe(0)
  })

  it('creates a vendor-specific rule, and shows the backend\'s conflict message instead of silently accepting an ambiguous rule', async () => {
    let n = 0
    const { backend } = open({ ...rules(), 'POST /admin/commission-rules': () => (++n === 1 ? err(409, 'commission_rule_conflict', "The active rule 'Alpha special' has the same scope and priority and overlaps in time.") : { body: rule(9) }) }, '/commission')
    await screen.findByText('Alpha special')
    await userEvent.click(screen.getByRole('button', { name: 'New rule' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Rule name/), 'Alpha again')
    await userEvent.selectOptions(await within(dialog).findByLabelText(/Vendor/), 'v-1')
    await userEvent.type(within(dialog).getByLabelText(/Percentage/), '7.5')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('same scope and priority')
    expect(backend.calls.find((c) => c.method === 'POST')!.body).toEqual({ name: 'Alpha again', applies_to: 'product', commission_type: 'percentage', commission_value: 7.5, priority: 0, is_active: true, vendor_id: 'v-1' })
    await userEvent.clear(within(dialog).getByLabelText(/Priority/))
    await userEvent.type(within(dialog).getByLabelText(/Priority/), '3')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
  })

  it('editing warns that recorded orders keep their commission and cannot change what a rule covers', async () => {
    const { backend } = open({ ...rules(), 'PUT /admin/commission-rules/r-2': { body: rule(2) } }, '/commission')
    await userEvent.click(within(await rowOf('Alpha special')).getByRole('button', { name: 'Edit' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText(/already placed keep the commission/)).toBeInTheDocument()
    expect(within(dialog).queryByLabelText(/Vendor/)).not.toBeInTheDocument()
    await userEvent.clear(within(dialog).getByLabelText(/Percentage/))
    await userEvent.type(within(dialog).getByLabelText(/Percentage/), '6')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(backend.count('PUT', '/admin/commission-rules/r-2')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'PUT')!.body).toMatchObject({ commission_value: 6, commission_type: 'percentage', priority: 2 })
    expect(backend.calls.find((c) => c.method === 'PUT')!.body).not.toHaveProperty('vendor_id')
  })

  it('tells the admin which rule would apply to a vendor and category (the same function checkout uses)', async () => {
    const { backend } = open({ ...rules(), 'GET /admin/commission-rules/resolve': (c: { query: URLSearchParams }) => ({ body: c.query.get('vendor_id') ? { rule: rule(2, { name: 'Alpha special', scope: 'vendor', commission_value: 5, priority: 2 }), note: null } : { rule: null, note: 'No active rule matches. Checkout follows the missing_rule_policy setting.' } }) }, '/commission')
    await screen.findByText('Alpha special')
    await userEvent.click(screen.getByRole('button', { name: 'Check' }))
    expect(await screen.findByText(/No active rule matches/)).toBeInTheDocument()
    await userEvent.selectOptions(await screen.findByLabelText('Vendor'), 'v-1')
    await userEvent.click(screen.getByRole('button', { name: 'Check' }))
    expect(await screen.findByText(/Checkout would apply/)).toHaveTextContent('Alpha special: 5%')
    expect(backend.calls.filter((c) => c.path === '/admin/commission-rules/resolve').at(-1)!.query.get('vendor_id')).toBe('v-1')
  })
})

describe('vendor settlements', () => {
  it('shows genuine records with gross, commission, deductions and net, filters, and offers no payout action', async () => {
    const { backend } = open({ 'GET /admin/settlements': { body: { ...page([settlement(1), settlement(2, { status: 'paid', payout_reference: 'NEFT-1', settled_at: '2026-03-15T10:00:00Z' })]), summary: { pending: 5000, ready: 21600, paid: 8000 } } } }, '/settlements')
    const row = await rowOf('VO-0001')
    expect(within(row).getByText('Vendor 1')).toBeInTheDocument()
    expect(within(row).getByText('₹24,000')).toBeInTheDocument()
    expect(within(row).getByText('₹2,400')).toBeInTheDocument()
    expect(within(row).getByText('₹21,600')).toBeInTheDocument()
    expect(within(row).getByText('Ready')).toBeInTheDocument()
    expect(within((await screen.findByText('Ready to pay vendors')).closest('.metric') as HTMLElement).getByText('₹21,600')).toBeInTheDocument()
    expect(screen.getByText(/does not transfer money to vendors/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /pay|transfer|payout|mark/i })).not.toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Status'), 'paid')
    await userEvent.selectOptions(await screen.findByLabelText('Vendor'), 'v-1')
    await userEvent.type(screen.getByLabelText('From'), '2026-03-01')
    await waitFor(() => { const q = backend.calls.filter((c) => c.path === '/admin/settlements').at(-1)!.query; expect([q.get('status'), q.get('vendor_id'), q.get('date_from')]).toEqual(['paid', 'v-1', '2026-03-01']) })
    await userEvent.click(within(await rowOf('VO-0002')).getByText('VO-0002'))
    expect(within(await screen.findByRole('dialog')).getByText('NEFT-1')).toBeInTheDocument()
  })
})
