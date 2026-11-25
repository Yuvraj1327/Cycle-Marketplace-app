import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { booking, bookingDetail, fulfilment, order, pickupItem, service, serviceCategory, timeline, vendorOrder } from '../../test/factories'
import { baseRoutes, err, fakeGateway, page, renderApp, vendor } from '../../test/utils'

const common = () => ({ ...baseRoutes(), 'GET /admin/vendors': { body: page([vendor(1, { business_name: 'Alpha Cycles', verification_status: 'approved' })]) }, 'GET /admin/service-categories': { body: [serviceCategory(1, { name: 'General Servicing' })] } })
const open = (routes: Record<string, unknown>, path: string) => renderApp({ path, gateway: fakeGateway({ token: 'tok' }), routes: { ...common(), ...routes } as never })
const rowOf = async (text: string | RegExp) => (await screen.findByText(text)).closest('tr') as HTMLElement
const tickets = { 'GET /admin/support-tickets': { body: page([]) } }

describe('order list', () => {
  const list = () => ({ 'GET /admin/orders': { body: page([order(1, { vendor_orders: [vendorOrder(1, { vendor_name: 'Alpha Cycles', items: [{ id: 'a', product_name: 'Trail Blazer', quantity: 2, unit_price: 1, line_total: 2 }, { id: 'b', product_name: 'Helmet', quantity: 1, unit_price: 1, line_total: 1 }, { id: 'c', product_name: 'Lock', quantity: 1, unit_price: 1, line_total: 1 }] })] }), order(2, { payment_method: 'online', payment_status: 'successful', status: 'completed' })]) } })

  it('shows reference, customer, vendor, product summary, amount, payment and status', async () => {
    open(list(), '/orders')
    const row = await rowOf('ORD-0001')
    expect(within(row).getByText('Asha Rao')).toBeInTheDocument()
    expect(within(row).getByText('+919800000001')).toBeInTheDocument()
    expect(within(row).getByText('Alpha Cycles')).toBeInTheDocument()
    expect(within(row).getByText('Trail Blazer ×2, Helmet +1 more')).toBeInTheDocument()
    expect(within(row).getByText('₹24,050')).toBeInTheDocument()
    expect(within(row).getByText('Cash on delivery')).toBeInTheDocument()
    expect(within(row).getByText('Pending')).toBeInTheDocument()
    expect(within(row).getByText('Confirmed')).toBeInTheDocument()
    expect(within(await rowOf('ORD-0002')).getByText('Online')).toBeInTheDocument()
  })

  it('offers only the statuses the backend supports and sends search, filters, dates and sort', async () => {
    const { backend } = open(list(), '/orders')
    await screen.findByText('ORD-0001')
    const status = screen.getByLabelText('Order status') as HTMLSelectElement
    expect([...status.options].map((o) => o.value)).toEqual(['', 'pending', 'confirmed', 'completed', 'cancelled'])
    await userEvent.selectOptions(status, 'completed')
    await userEvent.selectOptions(screen.getByLabelText('Payment status'), 'refunded')
    await userEvent.selectOptions(screen.getByLabelText('Payment method'), 'cod')
    await userEvent.selectOptions(screen.getByLabelText('Sort'), 'amount_high')
    await userEvent.type(screen.getByLabelText('From'), '2026-03-01')
    await userEvent.type(screen.getByLabelText('To'), '2026-03-31')
    await userEvent.type(screen.getByPlaceholderText(/Search order number/), 'asha')
    await waitFor(() => {
      const q = backend.calls.filter((c) => c.path === '/admin/orders').at(-1)!.query
      expect(Object.fromEntries(['status', 'payment_status', 'payment_method', 'sort', 'date_from', 'date_to', 'q'].map((k) => [k, q.get(k)]))).toEqual({ status: 'completed', payment_status: 'refunded', payment_method: 'cod', sort: 'amount_high', date_from: '2026-03-01', date_to: '2026-03-31', q: 'asha' })
    })
  })

  it('the Delivery & fulfilment tab opens the fulfilment overview', async () => {
    open({ ...list(), 'GET /admin/vendor-orders': { body: page([fulfilment(1), fulfilment(2, { vendor_name: 'Beta Bikes', status: 'delivered', delivered_at: '2026-03-12T09:00:00Z', payment_method: 'online', payment_status: 'successful' })]) } }, '/orders')
    await screen.findByText('ORD-0001')
    await userEvent.click(screen.getByRole('tab', { name: 'Delivery & fulfilment' }))
    expect(await screen.findByRole('heading', { name: 'Delivery & fulfilment' })).toBeInTheDocument()
    const row = await rowOf('VO-0001')
    expect(within(row).getByText('Vendor 1')).toBeInTheDocument()
    expect(within(row).getByText('Pune 411001')).toBeInTheDocument()
    expect(within(row).getByText('Accepted')).toBeInTheDocument()
    expect(within(await rowOf('VO-0002')).getByText('Delivered')).toBeInTheDocument()
    expect(screen.getByText(/no courier or GPS tracking/)).toBeInTheDocument()
  })
})

describe('fulfilment overview', () => {
  it('filters by fulfilment status, vendor and dates, and offers no way to change fulfilment', async () => {
    const { backend } = open({ 'GET /admin/vendor-orders': { body: page([fulfilment(1)]) } }, '/orders/fulfilment')
    await screen.findByText('VO-0001')
    const status = screen.getByLabelText('Fulfilment status') as HTMLSelectElement
    expect([...status.options].map((o) => o.value)).toEqual(['', 'pending', 'accepted', 'preparing', 'ready_for_dispatch', 'out_for_delivery', 'delivered', 'rejected', 'cancelled'])
    await userEvent.selectOptions(status, 'out_for_delivery')
    await userEvent.selectOptions(await screen.findByLabelText('Vendor'), 'v-1')
    await waitFor(() => {
      const q = backend.calls.filter((c) => c.path === '/admin/vendor-orders').at(-1)!.query
      expect([q.get('status'), q.get('vendor_id')]).toEqual(['out_for_delivery', 'v-1'])
    })
    expect(screen.queryByRole('button', { name: /deliver|dispatch|accept/i })).not.toBeInTheDocument()
  })

  it('shows an empty state and a retry on error', async () => {
    open({ 'GET /admin/vendor-orders': { body: page([]) } }, '/orders/fulfilment')
    expect(await screen.findByText('No fulfilment records')).toBeInTheDocument()
  })
})

describe('order details', () => {
  const detail = (over: Record<string, unknown> = {}) => ({
    'GET /admin/orders/o-1': { body: order(1, { vendor_orders: [vendorOrder(1, { status: 'accepted' }), vendorOrder(2, { status: 'delivered', delivered_at: '2026-03-12T09:00:00Z', items: [{ id: 'z', product_name: 'Disc Brake', product_brand: 'Shimano', product_model: null, product_condition: 'new', unit_price: 1850, quantity: 1, line_total: 1850 }] })], vendor_count: 2, payments: [{ id: 'pay-1', method: 'cod', amount: 24050, status: 'pending' }], ...over }) },
    'GET /admin/orders/o-1/timeline': { body: timeline() }, ...tickets,
  })

  it('shows the parent order and each vendor order separately, with purchase-time prices, payment and history', async () => {
    open(detail(), '/orders/o-1')
    expect(await screen.findByRole('heading', { name: 'Order ORD-0001' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Asha Rao' })).toHaveAttribute('href', '/customers/c-1')
    expect(screen.getByText(/1 MG Rd/)).toBeInTheDocument()
    expect(screen.getAllByText('₹24,050').length).toBeGreaterThan(0)
    expect(screen.getByText(/contains items from several vendors/)).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Vendor 1' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Vendor 2' })).toBeInTheDocument()
    expect(screen.getByText('Disc Brake')).toBeInTheDocument()
    expect(screen.getAllByText('Price at purchase').length).toBe(2)
    expect(screen.getAllByText('₹1,850')).toHaveLength(2)                      // price at purchase and line total
    expect(await screen.findByText(/Vendor One \(Vendor\)/)).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Details' })).toHaveAttribute('href', '/payments/pay-1')
  })

  it('cancelling the order needs a reason and sends one admin request; the page refreshes from the backend', async () => {
    let status = 'confirmed'
    const { backend } = open({ ...detail(), 'GET /admin/orders/o-1': () => ({ body: order(1, { status }) }), 'PATCH /admin/orders/o-1/status': () => { status = 'cancelled'; return { body: order(1, { status: 'cancelled' }) } } }, '/orders/o-1')
    await userEvent.click(await screen.findByRole('button', { name: 'Cancel order' }))
    const dialog = await screen.findByRole('dialog')
    const confirm = within(dialog).getByRole('button', { name: 'Cancel order' })
    expect(confirm).toBeDisabled()
    await userEvent.type(within(dialog).getByRole('textbox'), 'Fraud suspected')
    await userEvent.click(confirm)
    await waitFor(() => expect(backend.count('PATCH', '/admin/orders/o-1/status')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ status: 'cancelled', reason: 'Fraud suspected' })
    expect((await screen.findAllByText('Cancelled')).length).toBeGreaterThan(0)
    expect(screen.queryByRole('button', { name: 'Cancel order' })).not.toBeInTheDocument()
  })

  it('a vendor order can be cancelled with a reason, a delivered one cannot, and nothing can be marked delivered from here', async () => {
    const { backend } = open({ ...detail(), 'PATCH /admin/orders/o-1/status': err(409, 'not_cancellable', 'This order can no longer be cancelled.') }, '/orders/o-1')
    await screen.findByRole('heading', { name: 'Order ORD-0001' })
    const cancels = screen.getAllByRole('button', { name: 'Cancel this vendor order' })
    expect(cancels).toHaveLength(1)                                         // the delivered vendor order has none
    expect(screen.queryByRole('button', { name: /mark.*deliver|deliver/i })).not.toBeInTheDocument()
    await userEvent.click(cancels[0])
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByRole('textbox'), 'Vendor out of stock')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Cancel vendor order' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('can no longer be cancelled')
    expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ status: 'cancelled', vendor_order_id: 'vo-1', reason: 'Vendor out of stock' })
  })

  it('a cancelled order shows who cancelled it and why, with no cancel button', async () => {
    open(detail({ status: 'cancelled', cancelled_reason: 'Customer asked', cancelled_by_role: 'customer', cancelled_at: '2026-03-11T08:00:00Z' }), '/orders/o-1')
    expect(await screen.findByText(/Cancelled .* by customer\. Reason: Customer asked/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Cancel order' })).not.toBeInTheDocument()
  })

  it('complaints raised against the order can be triaged', async () => {
    const ticket = { id: 't-1', ticket_number: 'TKT-00000001', type: 'complaint', subject: 'Late delivery', description: 'Arrived a week late', status: 'open', order_id: 'o-1', service_booking_id: null, resolution: null, resolved_at: null, created_at: '2026-03-12T09:00:00Z', updated_at: '2026-03-12T09:00:00Z', requester_id: 'c-1', assigned_to: null, admin_notes: null }
    const { backend } = open({ ...detail(), 'GET /admin/support-tickets': { body: page([ticket]) }, 'PATCH /admin/support-tickets/t-1': { body: { ...ticket, status: 'resolved' } } }, '/orders/o-1')
    expect(await screen.findByText('TKT-00000001')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Review' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.selectOptions(within(dialog).getByLabelText('Status'), 'resolved')
    await userEvent.type(within(dialog).getByLabelText('Resolution'), 'Refunded delivery fee')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ status: 'resolved', resolution: 'Refunded delivery fee' }))
  })
})

describe('services', () => {
  const list = () => ({ 'GET /admin/services': { body: page([service(1), service(2, { name: 'Gear tune', is_active: false, is_available: false, vendor_name: 'Beta Bikes' })]) } })

  it('lists services with vendor, category, price, time, availability and listing status; filters reach the backend', async () => {
    const { backend } = open(list(), '/services?category_id=sc-1')
    const row = await rowOf('Full service 1')
    expect(within(row).getByText('General Servicing')).toBeInTheDocument()
    expect(within(row).getByRole('link', { name: 'Alpha Cycles' })).toHaveAttribute('href', '/vendors/v-1')
    expect(within(row).getByText('₹499')).toBeInTheDocument()
    expect(within(row).getByText('120 min')).toBeInTheDocument()
    expect(within(row).getByText('Available')).toBeInTheDocument()
    const off = await rowOf('Gear tune')
    expect(within(off).getByText('Unavailable')).toBeInTheDocument()
    expect(within(off).getByRole('button', { name: 'Activate' })).toBeInTheDocument()
    expect(backend.calls.find((c) => c.path === '/admin/services')!.query.get('category_id')).toBe('sc-1')
    await userEvent.selectOptions(screen.getByLabelText('Availability'), 'false')
    await userEvent.selectOptions(screen.getByLabelText('Listing'), 'true')
    await waitFor(() => { const q = backend.calls.filter((c) => c.path === '/admin/services').at(-1)!.query; expect([q.get('is_available'), q.get('is_active')]).toEqual(['false', 'true']) })
  })

  it('deactivating needs a reason for the vendor and sends it; the admin cannot create or edit a service', async () => {
    const { backend } = open({ ...list(), 'PATCH /admin/services/s-1/status': { body: service(1, { is_active: false }) } }, '/services')
    expect(screen.queryByRole('button', { name: /new service|add service|edit/i })).not.toBeInTheDocument()
    await userEvent.click(within(await rowOf('Full service 1')).getByRole('button', { name: 'Deactivate' }))
    const dialog = await screen.findByRole('dialog')
    const confirm = within(dialog).getByRole('button', { name: 'Deactivate' })
    expect(confirm).toBeDisabled()
    await userEvent.type(within(dialog).getByRole('textbox'), 'Misleading price')
    await userEvent.click(confirm)
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ is_active: false, reason: 'Misleading price' }))
  })

  it('opens a details view', async () => {
    open(list(), '/services')
    await userEvent.click(within(await rowOf('Full service 1')).getByRole('button', { name: 'Details' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText('Complete check and tune-up.')).toBeInTheDocument()
    expect(within(dialog).getByText('Mon, Tue')).toBeInTheDocument()
  })
})

describe('service categories', () => {
  it('manages service categories with the same rules: blocks deleting one in use, creates with validation', async () => {
    const { backend } = open({ 'GET /admin/service-categories': { body: [serviceCategory(1, { name: 'General Servicing', service_count: 2 }), serviceCategory(2, { name: 'Brake Repair' })] }, 'POST /admin/service-categories': { body: serviceCategory(3) } }, '/service-categories')
    expect(within(await rowOf('General Servicing')).getByRole('button', { name: 'Delete' })).toBeDisabled()
    expect(within(await rowOf('Brake Repair')).getByRole('button', { name: 'Delete' })).toBeEnabled()
    expect(within(await rowOf('Brake Repair')).getByRole('link', { name: 'View services' })).toHaveAttribute('href', '/services?category_id=sc-2')
    await userEvent.click(screen.getByRole('button', { name: 'New category' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).queryByLabelText(/Type/)).not.toBeInTheDocument()
    await userEvent.type(within(dialog).getByLabelText(/Name/), 'Gear Adjustment')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'POST')!.body).toEqual({ name: 'Gear Adjustment', description: null, sort_order: 0, is_active: true }))
  })
})

describe('service bookings', () => {
  const list = () => ({ 'GET /admin/service-bookings': { body: page([booking(1), booking(2, { status: 'in_service', needs_pickup_dropoff: false, pickup_stage: null, confirmed: { date: '2026-03-22', slot_start: '14:00:00' } })]) } })

  it('lists every column, filters by the supported statuses, vendor and dates', async () => {
    const { backend } = open(list(), '/service-bookings')
    const row = await rowOf('BKG-0001')
    expect(within(row).getByText('Asha Rao')).toBeInTheDocument()
    expect(within(row).getByText('Alpha Cycles')).toBeInTheDocument()
    expect(within(row).getByText('General Servicing')).toBeInTheDocument()
    expect(within(row).getByText('Pending')).toBeInTheDocument()
    expect(within(row).getByText('Required')).toBeInTheDocument()
    expect(within(row).getByText('₹499')).toBeInTheDocument()
    expect(within(await rowOf('BKG-0002')).getByText('Not needed')).toBeInTheDocument()
    expect(within(await rowOf('BKG-0002')).getByText(/confirmed/)).toBeInTheDocument()
    const status = screen.getByLabelText('Status') as HTMLSelectElement
    expect([...status.options].map((o) => o.value)).toEqual(['', 'pending', 'accepted', 'rejected', 'picked_up', 'in_service', 'ready_for_delivery', 'completed', 'cancelled'])
    await userEvent.selectOptions(status, 'in_service')
    await userEvent.selectOptions(await screen.findByLabelText('Vendor'), 'v-1')
    await userEvent.type(screen.getByLabelText('From'), '2026-03-01')
    await userEvent.type(screen.getByPlaceholderText(/Search booking number/), 'asha')
    await waitFor(() => {
      const q = backend.calls.filter((c) => c.path === '/admin/service-bookings').at(-1)!.query
      expect([q.get('status'), q.get('vendor_id'), q.get('date_from'), q.get('q')]).toEqual(['in_service', 'v-1', '2026-03-01', 'asha'])
    })
  })

  const detailRoutes = (over: Record<string, unknown> = {}) => ({ 'GET /admin/service-bookings/bk-1': { body: bookingDetail(1, over) }, 'GET /admin/service-bookings/bk-1/timeline': { body: [{ ...timeline()[0], scope: 'booking' }] }, ...tickets })

  it('shows customer, vendor, cycle, issue, schedule, charges, notes, pickup, photos and history, read-only', async () => {
    open(detailRoutes(), '/service-bookings/bk-1')
    expect(await screen.findByRole('heading', { name: 'Booking BKG-0001' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Asha Rao' })).toHaveAttribute('href', '/customers/c-1')
    expect(screen.getByRole('link', { name: 'Alpha Cycles' })).toHaveAttribute('href', '/vendors/v-1')
    expect(screen.getByText('Hero Sprint')).toBeInTheDocument()
    expect(screen.getByText('Brakes squeal')).toBeInTheDocument()
    expect(screen.getByText('Replaced brake pads')).toBeInTheDocument()
    expect(screen.getByText('Brake pads worn')).toBeInTheDocument()
    expect(screen.getByText('₹749')).toBeInTheDocument()
    expect(screen.getByText('Call at gate')).toBeInTheDocument()
    expect(screen.getByAltText('Cycle photo from the customer')).toHaveAttribute('src', 'https://signed.test/1.jpg')
    expect(screen.getByRole('button', { name: 'Reject' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /accept|complete|add note|add charge/i })).not.toBeInTheDocument()   // vendor decisions and records stay the vendor's
    expect(screen.getByText('Repair status history')).toBeInTheDocument()
  })

  it('rejecting or cancelling needs a recorded reason and goes to the backend', async () => {
    const { backend } = open({ ...detailRoutes(), 'PATCH /admin/service-bookings/bk-1/status': { body: bookingDetail(1, { status: 'rejected' }) } }, '/service-bookings/bk-1')
    await userEvent.click(await screen.findByRole('button', { name: 'Reject' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByRole('button', { name: 'Reject booking' })).toBeDisabled()
    await userEvent.type(within(dialog).getByRole('textbox'), 'Provider cannot service this cycle')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Reject booking' }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ status: 'rejected', reason: 'Provider cannot service this cycle' }))
  })

  it('a completed booking offers no administrative status change', async () => {
    open(detailRoutes({ status: 'completed' }), '/service-bookings/bk-1')
    await screen.findByRole('heading', { name: 'Booking BKG-0001' })
    expect(screen.queryByRole('button', { name: /reject|cancel booking/i })).not.toBeInTheDocument()
  })
})

describe('pickup and drop-off', () => {
  const list = () => ({ 'GET /admin/pickup-requests': { body: page([pickupItem(1), pickupItem(2, { booking_status: 'picked_up', pickup: { ...pickupItem(2).pickup, pickup_status: 'completed', pickup_stage: 'picked_up', scheduled_pickup_at: '2026-03-20T05:00:00Z' } })]) } })

  it('keeps the booking status separate from the pickup and return statuses, with addresses, times and charges', async () => {
    const { backend } = open(list(), '/pickups')
    const row = await rowOf('BKG-0001')
    expect(within(row).getByText('Asha Rao')).toBeInTheDocument()
    expect(within(row).getAllByText('1 MG Rd, Pune 411001')).toHaveLength(2)
    expect(within(row).getAllByText('Not scheduled')).toHaveLength(2)
    expect(within(row).getAllByText('Requested', { selector: '.badge' })).toHaveLength(2)         // pickup and return are each their own status
    expect(within(row).getByText('₹100')).toBeInTheDocument()
    expect(within(row).getByText('Accepted')).toBeInTheDocument()                           // booking status in its own column
    expect(within(await rowOf('BKG-0002')).getAllByText('Picked up', { selector: '.badge' })).toHaveLength(2)   // booking status + pickup status, each in its own column
    await userEvent.selectOptions(screen.getByLabelText('Pickup status'), 'scheduled')
    await userEvent.selectOptions(screen.getByLabelText('Return status'), 'failed')
    await waitFor(() => { const q = backend.calls.filter((c) => c.path === '/admin/pickup-requests').at(-1)!.query; expect([q.get('pickup_status'), q.get('delivery_status')]).toEqual(['scheduled', 'failed']) })
  })

  it('coordinating needs a time to schedule and sends only what changed', async () => {
    const { backend } = open({ ...list(), 'PATCH /admin/pickup-requests/pk-1/status': { body: pickupItem(1) } }, '/pickups')
    await userEvent.click(within(await rowOf('BKG-0001')).getByRole('button', { name: 'Coordinate' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText(/cannot be set here/)).toBeInTheDocument()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(await within(dialog).findByText('Nothing was changed.')).toBeInTheDocument()
    await userEvent.selectOptions(within(dialog).getByLabelText('Pickup status'), 'scheduled')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(await within(dialog).findByText('Choose the pickup time to schedule it.')).toBeInTheDocument()
    expect(backend.count('PATCH', '/admin/pickup-requests/pk-1/status')).toBe(0)
    await userEvent.type(within(dialog).getByLabelText('Pickup time'), '2026-03-21T10:30')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(backend.count('PATCH', '/admin/pickup-requests/pk-1/status')).toBe(1))
    const body = backend.calls.find((c) => c.method === 'PATCH')!.body as Record<string, unknown>
    expect(Object.keys(body).sort()).toEqual(['pickup_status', 'scheduled_pickup_at'])
    expect(body.pickup_status).toBe('scheduled')
  })

  it('shows the backend\'s refusal inside the dialog', async () => {
    open({ ...list(), 'PATCH /admin/pickup-requests/pk-1/status': err(409, 'invalid_transition', 'This status change is not allowed.') }, '/pickups')
    await userEvent.click(within(await rowOf('BKG-0001')).getByRole('button', { name: 'Coordinate' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.selectOptions(within(dialog).getByLabelText('Pickup status'), 'failed')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('This status change is not allowed.')
  })
})
