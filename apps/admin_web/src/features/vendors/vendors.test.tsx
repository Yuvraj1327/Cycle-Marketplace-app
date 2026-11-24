import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { baseRoutes, err, fakeGateway, page, renderApp, vendor } from '../../test/utils'

const open = (routes: ReturnType<typeof baseRoutes>, path = '/vendors') => renderApp({ path, gateway: fakeGateway({ token: 'tok' }), routes })
const rowOf = async (name: string) => (await screen.findByText(name)).closest('tr') as HTMLElement

describe('vendor list', () => {
  it('shows every column the admin needs and the right actions for each verification state', async () => {
    open({ ...baseRoutes(), 'GET /admin/vendors': { body: page([
      vendor(1, { business_name: 'Pending Cycles', verification_status: 'pending' }),
      vendor(2, { business_name: 'Live Cycles', verification_status: 'approved', business_types: ['bicycle_shop', 'service_provider'] }),
      vendor(3, { business_name: 'Rejected Cycles', verification_status: 'rejected' }),
      vendor(4, { business_name: 'Banned Cycles', verification_status: 'suspended', account_status: 'inactive' }),
    ]) } })
    const pend = await rowOf('Pending Cycles')
    expect(within(pend).getByText('Owner 1')).toBeInTheDocument()
    expect(within(pend).getByText('Pune, MH')).toBeInTheDocument()
    expect(within(pend).getByText('Pending')).toBeInTheDocument()
    expect(within(pend).getByRole('button', { name: 'Review' })).toBeInTheDocument()
    expect(within(pend).getByRole('button', { name: 'Approve' })).toBeInTheDocument()
    expect(within(pend).getByRole('button', { name: 'Reject' })).toBeInTheDocument()
    expect(within(pend).queryByRole('button', { name: 'Suspend' })).not.toBeInTheDocument()
    const live = await rowOf('Live Cycles')
    expect(within(live).getByText('Bicycle shop, Service provider')).toBeInTheDocument()
    expect(within(live).getByRole('button', { name: 'Suspend' })).toBeInTheDocument()
    expect(within(live).queryByRole('button', { name: 'Approve' })).not.toBeInTheDocument()
    expect(within(await rowOf('Rejected Cycles')).getByRole('button', { name: 'Approve after review' })).toBeInTheDocument()
    const banned = await rowOf('Banned Cycles')
    expect(within(banned).getByRole('button', { name: 'Reinstate' })).toBeInTheDocument()
    expect(within(banned).getByRole('button', { name: 'Activate' })).toBeInTheDocument()       // account status is separate from verification
  })

  it('the Pending applications tab and every filter are sent to the backend', async () => {
    const { backend } = open({ ...baseRoutes(), 'GET /admin/vendors': { body: page([vendor(1)]) } })
    await screen.findByText('Shop 1')
    await userEvent.click(screen.getByRole('tab', { name: 'Pending applications' }))
    await waitFor(() => expect(backend.calls.at(-1)!.query.get('verification_status')).toBe('pending'))
    await userEvent.selectOptions(screen.getByLabelText('Business type'), 'service_provider')
    await waitFor(() => expect(backend.calls.at(-1)!.query.get('business_type')).toBe('service_provider'))
    await userEvent.selectOptions(screen.getByLabelText('Account'), 'inactive')
    await waitFor(() => expect(backend.calls.at(-1)!.query.get('account_status')).toBe('inactive'))
    await userEvent.type(screen.getByPlaceholderText(/Search business/), 'nashik')
    await waitFor(() => expect(backend.calls.at(-1)!.query.get('q')).toBe('nashik'))
    const last = backend.calls.at(-1)!.query
    expect(last.get('verification_status')).toBe('pending')
    expect(last.get('limit')).toBe('20')
  })

  it('opens pre-filtered from a dashboard link', async () => {
    const { backend } = open({ ...baseRoutes(), 'GET /admin/vendors': { body: page([]) } }, '/vendors?verification_status=pending')
    expect(await screen.findByText('No pending applications')).toBeInTheDocument()
    expect(backend.calls.find((c) => c.path === '/admin/vendors')!.query.get('verification_status')).toBe('pending')
    expect(screen.getByRole('tab', { name: 'Pending applications' })).toHaveAttribute('aria-selected', 'true')
  })
})

describe('vendor decisions', () => {
  function setup(initial = 'pending', handlers: Record<string, never> = {}) {
    let status = initial
    return renderApp({
      path: '/vendors', gateway: fakeGateway({ token: 'tok' }),
      routes: {
        ...baseRoutes(),
        'GET /admin/vendors': () => ({ body: page([vendor(1, { business_name: 'Pending Cycles', verification_status: status })]) }),
        'POST /admin/vendors/v-1/approve': () => { status = 'approved'; return { body: vendor(1, { verification_status: 'approved' }) } },
        'POST /admin/vendors/v-1/reject': () => { status = 'rejected'; return { body: vendor(1, { verification_status: 'rejected' }) } },
        'POST /admin/vendors/v-1/suspend': () => { status = 'suspended'; return { body: vendor(1, { verification_status: 'suspended' }) } },
        ...handlers,
      },
    })
  }

  it('approve: confirmation first, one request, the row changes only after the backend answers', async () => {
    const { backend } = setup()
    const row = await rowOf('Pending Cycles')
    await userEvent.click(within(row).getByRole('button', { name: 'Approve' }))
    const dialog = await screen.findByRole('dialog')
    expect(backend.count('POST', '/admin/vendors/v-1/approve')).toBe(0)
    await userEvent.dblClick(within(dialog).getByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(backend.count('POST', '/admin/vendors/v-1/approve')).toBe(1)
    expect(await screen.findByText('Vendor approved')).toBeInTheDocument()
    await waitFor(async () => expect(within(await rowOf('Pending Cycles')).getByText('Approved')).toBeInTheDocument())
    expect(within(await rowOf('Pending Cycles')).getByRole('button', { name: 'Suspend' })).toBeInTheDocument()
  })

  it('reject requires a reason of at least 3 characters and sends it to the backend', async () => {
    const { backend } = setup()
    await userEvent.click(within(await rowOf('Pending Cycles')).getByRole('button', { name: 'Reject' }))
    const dialog = await screen.findByRole('dialog')
    const confirm = within(dialog).getByRole('button', { name: 'Reject' })
    expect(confirm).toBeDisabled()
    await userEvent.type(within(dialog).getByLabelText(/Reason shown to the vendor/), 'ab')
    expect(confirm).toBeDisabled()
    await userEvent.type(within(dialog).getByLabelText(/Reason shown to the vendor/), 'c unclear photos')
    await userEvent.click(confirm)
    await waitFor(() => expect(backend.count('POST', '/admin/vendors/v-1/reject')).toBe(1))
    expect(backend.calls.find((c) => c.path.endsWith('/reject'))!.body).toEqual({ reason: 'abc unclear photos' })
    expect(await screen.findByText('Application rejected')).toBeInTheDocument()
  })

  it('a repeated approval (409 already_approved) is shown to the admin and the dialog stays open', async () => {
    setup('pending', { 'POST /admin/vendors/v-1/approve': err(409, 'already_approved', 'This vendor is already approved.') } as never)
    await userEvent.click(within(await rowOf('Pending Cycles')).getByRole('button', { name: 'Approve' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Approve' }))
    expect(await within(dialog).findByText('This vendor is already approved.')).toBeInTheDocument()
    expect(screen.queryByText('Vendor approved')).not.toBeInTheDocument()
  })

  it('suspend needs a reason; a forbidden answer is surfaced, not hidden', async () => {
    setup('approved', { 'POST /admin/vendors/v-1/suspend': err(409, 'invalid_transition', 'A vendor that is rejected cannot be suspended.') } as never)
    await userEvent.click(within(await rowOf('Pending Cycles')).getByRole('button', { name: 'Suspend' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByRole('button', { name: 'Suspend' })).toBeDisabled()
    await userEvent.type(within(dialog).getByLabelText(/Reason/), 'Counterfeit parts')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Suspend' }))
    expect(await within(dialog).findByText('A vendor that is rejected cannot be suspended.')).toBeInTheDocument()
  })

  it('vendor account activation/deactivation uses the account-status endpoint with a reason', async () => {
    const { backend } = setup('approved', { 'PATCH /admin/vendors/v-1/account-status': { body: vendor(1) } } as never)
    await userEvent.click(within(await rowOf('Pending Cycles')).getByRole('button', { name: 'Deactivate' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Reason/), 'Owner request')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Deactivate' }))
    await waitFor(() => expect(backend.count('PATCH', '/admin/vendors/v-1/account-status')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ status: 'inactive', reason: 'Owner request' })
  })
})

describe('vendor application review (detail)', () => {
  const detail = (over: Record<string, unknown> = {}) => ({
    ...vendor(1, { business_name: 'Spoke & Co', verification_status: 'pending', product_count: 3 }),
    owner_phone: '+919822200000', description: 'We fix and sell cycles.', address_line1: '5 FC Road', address_line2: null, postal_code: '411004',
    operating_hours: { mon: { closed: false, open: '09:00', close: '18:00' }, sun: { closed: true } },
    shop_image_paths: ['u/shop/a.jpg'], shop_image_urls: ['https://img.test/shop-images/u/shop/a.jpg'], service_area_postal_codes: ['411001', '411002'], service_radius_km: 12,
    pickup_available: true, rejection_reason: null, review_notes: null, reviewed_by: null, reviewed_at: null, updated_at: '2026-02-03T00:00:00Z',
    activity: [{ at: '2026-02-05T09:00:00Z', action: 'vendor_suspended', actor_id: 'admin-9999', details: { reason: 'Counterfeit parts' } }], ...over })

  it('shows the whole application so the admin can inspect it before deciding', async () => {
    open({ ...baseRoutes(), 'GET /admin/vendors/v-1': { body: detail() }, 'GET /admin/products': { body: page([]) } }, '/vendors/v-1')
    expect(await screen.findByRole('heading', { name: /Spoke & Co/ })).toBeInTheDocument()
    expect(screen.getByText('Application waiting for review')).toBeInTheDocument()
    expect(screen.getByText('We fix and sell cycles.')).toBeInTheDocument()
    expect(screen.getByText('5 FC Road, Pune, MH 411004')).toBeInTheDocument()
    expect(screen.getByText('09:00 – 18:00')).toBeInTheDocument()
    expect(screen.getByText('411001, 411002')).toBeInTheDocument()
    expect(screen.getByText('Offered')).toBeInTheDocument()
    expect(screen.getByText('12 km')).toBeInTheDocument()
    expect(screen.getByAltText('Spoke & Co shop photo 1')).toHaveAttribute('src', 'https://img.test/shop-images/u/shop/a.jpg')
    expect(screen.getByText('Reason: Counterfeit parts')).toBeInTheDocument()
    const decision = screen.getByText('Decision').closest('section') as HTMLElement
    expect(within(decision).getByRole('button', { name: 'Approve' })).toBeInTheDocument()
    expect(within(decision).getByRole('button', { name: 'Reject' })).toBeInTheDocument()
  })

  it('loads associated products / orders / bookings for THIS vendor, on demand', async () => {
    const { backend } = open({ ...baseRoutes(), 'GET /admin/vendors/v-1': { body: detail({ verification_status: 'approved' }) },
      'GET /admin/products': { body: page([{ id: 'p1', name: 'Trail Blazer', brand: 'Hero', model: 'TB', price: 24999, stock_quantity: 4, approval_status: 'approved', is_active: true, product_type: 'new_cycle', primary_image_url: null }]) } }, '/vendors/v-1')
    expect(await screen.findByText('Trail Blazer')).toBeInTheDocument()
    expect(backend.calls.find((c) => c.path === '/admin/products')!.query.get('vendor_id')).toBe('v-1')
    expect(backend.count('GET', '/admin/orders')).toBe(0)
    await userEvent.click(screen.getByRole('tab', { name: 'Orders' }))
    await screen.findByText('No orders')
    expect(backend.calls.find((c) => c.path === '/admin/orders')!.query.get('vendor_id')).toBe('v-1')
  })

  it('approving from the detail page refreshes the decision panel from the backend', async () => {
    let status = 'pending'
    open({ ...baseRoutes(), 'GET /admin/vendors/v-1': () => ({ body: detail({ verification_status: status }) }), 'GET /admin/products': { body: page([]) },
      'POST /admin/vendors/v-1/approve': () => { status = 'approved'; return { body: detail({ verification_status: 'approved' }) } } }, '/vendors/v-1')
    await screen.findByRole('heading', { name: /Spoke & Co/ })
    const decision = screen.getByText('Decision').closest('section') as HTMLElement
    await userEvent.click(within(decision).getByRole('button', { name: 'Approve' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(within(screen.getByText('Decision').closest('section') as HTMLElement).getByRole('button', { name: 'Suspend' })).toBeInTheDocument())
  })

  it('404 → Vendor not found', async () => {
    open({ ...baseRoutes(), 'GET /admin/vendors/v-9': err(404, 'not_found', 'Vendor not found.') }, '/vendors/v-9')
    expect(await screen.findByText('Vendor not found')).toBeInTheDocument()
  })
})
