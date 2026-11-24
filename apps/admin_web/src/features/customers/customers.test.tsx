import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { baseRoutes, customer, err, fakeGateway, page, renderApp } from '../../test/utils'

const open = (routes: ReturnType<typeof baseRoutes>, path = '/customers') => renderApp({ path, gateway: fakeGateway({ token: 'tok' }), routes })

describe('customer list', () => {
  it('shows backend customers with counts, status badges and actions', async () => {
    open({ ...baseRoutes(), 'GET /admin/customers': { body: page([customer(1, { full_name: 'Asha Rao', order_count: 3 }), customer(2, { status: 'restricted' })]) } })
    const row = (await screen.findByText('Asha Rao')).closest('tr') as HTMLElement
    expect(within(row).getByText('c1@example.com')).toBeInTheDocument()
    expect(within(row).getByText('3')).toBeInTheDocument()
    expect(within(row).getByText('Active')).toBeInTheDocument()
    expect(within(row).getByRole('button', { name: 'Deactivate' })).toBeInTheDocument()
    expect(within(row).getByRole('button', { name: 'Restrict' })).toBeInTheDocument()
    expect(within(row).queryByRole('button', { name: 'Activate' })).not.toBeInTheDocument()
    const r2 = screen.getByText('Customer 2').closest('tr') as HTMLElement
    expect(within(r2).getByRole('button', { name: 'Activate' })).toBeInTheDocument()
    expect(within(r2).getByText('Restricted')).toBeInTheDocument()
  })

  it('search is sent to the backend (debounced), filters reset to page 1 and sorting is passed through', async () => {
    const { backend } = open({ ...baseRoutes(), 'GET /admin/customers': { body: page([customer(1)], { total: 45, pages: 3 }) } })
    await screen.findByText('Customer 1')
    await userEvent.type(screen.getByPlaceholderText('Search name, e-mail or phone'), 'asha')
    await waitFor(() => expect(backend.calls.some((c) => c.path === '/admin/customers' && c.query.get('q') === 'asha')).toBe(true))
    await userEvent.selectOptions(screen.getByLabelText('Status'), 'restricted')
    await waitFor(() => expect(backend.calls.at(-1)!.query.get('status')).toBe('restricted'))
    await userEvent.selectOptions(screen.getByLabelText('Sort'), 'name')
    await waitFor(() => expect(backend.calls.at(-1)!.query.get('sort')).toBe('name'))
    expect(backend.calls.at(-1)!.query.get('page')).toBe('1')
  })

  it('paginates from the backend and never loads everything at once', async () => {
    const { backend } = open({ ...baseRoutes(), 'GET /admin/customers': (c) => ({ body: page([customer(Number(c.query.get('page')))], { total: 45, pages: 3, page: Number(c.query.get('page')) }) }) })
    await screen.findByText('Customer 1')
    expect(screen.getByText('1–20 of 45')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Next' }))
    await screen.findByText('Customer 2')
    expect(screen.getByText('Page 2 of 3')).toBeInTheDocument()
    expect(backend.calls.filter((c) => c.path === '/admin/customers').every((c) => c.query.get('limit') === '20')).toBe(true)
  })

  it('empty and error states', async () => {
    let fail = true
    open({ ...baseRoutes(), 'GET /admin/customers': () => (fail ? err(500, 'internal_error', 'An unexpected error occurred.') : { body: page([]) }) })
    expect(await screen.findByText('Something went wrong')).toBeInTheDocument()
    fail = false
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('No customers found')).toBeInTheDocument()
  })
})

describe('customer account management', () => {
  const routes = (status = 'active', patch?: () => { status?: number; body?: unknown }) => ({
    ...baseRoutes(),
    'GET /admin/customers': { body: page([customer(1, { full_name: 'Asha Rao', status })]) },
    'PATCH /admin/customers/c-1/status': patch ?? ((c: { body: unknown }) => ({ body: customer(1, { status: (c.body as { status: string }).status }) })),
  })

  it('deactivation needs a reason, confirms first, and updates the list only after the backend replies', async () => {
    let done = false
    const r = { ...routes(), 'GET /admin/customers': () => ({ body: page([customer(1, { full_name: 'Asha Rao', status: done ? 'inactive' : 'active' })]) }),
      'PATCH /admin/customers/c-1/status': () => { done = true; return { body: customer(1, { status: 'inactive' }) } } }
    const { backend } = open(r)
    await userEvent.click(await screen.findByRole('button', { name: 'Deactivate' }))
    const dialog = await screen.findByRole('dialog')
    const confirm = within(dialog).getByRole('button', { name: 'Deactivate' })
    expect(confirm).toBeDisabled()                                                       // reason required
    expect(backend.count('PATCH', '/admin/customers/c-1/status')).toBe(0)
    await userEvent.type(within(dialog).getByLabelText(/Reason/), 'Chargeback fraud')
    await userEvent.click(confirm)
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    const patch = backend.calls.find((c) => c.method === 'PATCH')!
    expect(patch.body).toEqual({ status: 'inactive', reason: 'Chargeback fraud' })
    expect(await screen.findByText('Customer deactivated')).toBeInTheDocument()
    expect(within((await screen.findByText('Asha Rao')).closest('tr') as HTMLElement).getByText('Inactive')).toBeInTheDocument()
  })

  it('a backend refusal keeps the dialog open, shows the error and changes nothing', async () => {
    const { backend } = open(routes('active', () => err(409, 'no_change', 'The account is already inactive.')))
    await userEvent.click(await screen.findByRole('button', { name: 'Deactivate' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Reason/), 'duplicate click')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Deactivate' }))
    expect(await within(dialog).findByText('The account is already inactive.')).toBeInTheDocument()
    expect(screen.queryByText('Customer deactivated')).not.toBeInTheDocument()
    expect(within(screen.getByText('Asha Rao').closest('tr') as HTMLElement).getByText('Active')).toBeInTheDocument()
    expect(backend.count('PATCH', '/admin/customers/c-1/status')).toBe(1)
  })

  it('double-clicking confirm submits once', async () => {
    const { backend } = open(routes('active', () => ({ body: customer(1, { status: 'restricted' }) })))
    await userEvent.click(await screen.findByRole('button', { name: 'Restrict' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Reason/), 'Abuse reports')
    const btn = within(dialog).getByRole('button', { name: 'Restrict' })
    await userEvent.dblClick(btn)
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(backend.count('PATCH', '/admin/customers/c-1/status')).toBe(1)
  })

  it('activating needs no reason', async () => {
    const { backend } = open(routes('inactive'))
    await userEvent.click(await screen.findByRole('button', { name: 'Activate' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Activate' }))
    await waitFor(() => expect(backend.count('PATCH', '/admin/customers/c-1/status')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ status: 'active' })
  })
})

describe('customer details', () => {
  const detail = () => ({ ...customer(1, { full_name: 'Asha Rao' }), updated_at: '2026-02-03T00:00:00Z', addresses: [{ id: 'a1', label: 'Home', recipient_name: 'Asha', address_line1: '12 MG Road', city: 'Pune', state: 'MH', postal_code: '411001', is_default: true, phone: '+919800000001' }],
    activity: [{ at: '2026-02-04T09:00:00Z', action: 'customer_restricted', actor_id: 'admin-1234', details: { reason: 'Chargebacks' } }] })

  it('shows profile, addresses, order and booking history, and the audit trail', async () => {
    open({ ...baseRoutes(), 'GET /admin/customers/c-1': { body: detail() },
      'GET /admin/orders': { body: page([{ id: 'o1', order_number: 'ORD-1', status: 'confirmed', payment_method: 'cod', payment_status: 'pending', total_amount: 1050, item_count: 1, vendor_count: 1, created_at: '2026-02-01T10:00:00Z', customer: null, vendor_orders: [] }]) },
      'GET /admin/service-bookings': { body: page([]) } }, '/customers/c-1')
    expect(await screen.findByRole('heading', { name: /Asha Rao/ })).toBeInTheDocument()
    expect(await screen.findByText(/12 MG Road/)).toBeInTheDocument()
    expect(await screen.findByText('ORD-1')).toBeInTheDocument()
    expect(screen.getByText('₹1,050')).toBeInTheDocument()
    expect(await screen.findByText('No bookings')).toBeInTheDocument()
    expect(screen.getByText('Reason: Chargebacks')).toBeInTheDocument()
    expect(screen.getByText(/never visible to administrators/)).toBeInTheDocument()
  })

  it('queries order/booking history by this customer only; unknown customer shows not found', async () => {
    const { backend } = open({ ...baseRoutes(), 'GET /admin/customers/c-1': { body: detail() } }, '/customers/c-1')
    await screen.findByRole('heading', { name: /Asha Rao/ })
    await waitFor(() => expect(backend.calls.some((c) => c.path === '/admin/orders')).toBe(true))
    expect(backend.calls.find((c) => c.path === '/admin/orders')!.query.get('customer_id')).toBe('c-1')
    expect(backend.calls.find((c) => c.path === '/admin/service-bookings')!.query.get('customer_id')).toBe('c-1')
  })

  it('404 → Customer not found', async () => {
    open({ ...baseRoutes(), 'GET /admin/customers/c-9': err(404, 'not_found', 'Customer not found.') }, '/customers/c-9')
    expect(await screen.findByText('Customer not found')).toBeInTheDocument()
  })
})
