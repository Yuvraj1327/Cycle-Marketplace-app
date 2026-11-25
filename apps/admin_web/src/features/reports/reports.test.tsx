import { fireEvent, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { baseRoutes, err, fakeGateway, renderApp } from '../../test/utils'

const rep = (kind: string, data: unknown) => ({ body: { kind, period_from: '2026-03-01', period_to: '2026-03-03', timezone: 'Asia/Kolkata', data } })
const days = (vals: number[], value = false) => vals.map((n, i) => ({ day: `2026-03-0${i + 1}`, count: n, ...(value ? { value: n * 1000 } : {}) }))
const open = (kind: string, data: unknown, path?: string) => renderApp({ path: path ?? `/reports/${kind}`, gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), [`GET /admin/reports/${kind}`]: rep(kind, data) } as never })
const metric = (label: string) => (screen.getByText(label, { selector: '.metric-label' }).closest('.metric') as HTMLElement)

describe('reports', () => {
  it('order report: counts, value, status distribution and per-day charts from real data', async () => {
    open('orders', { total: 12, value: 45000.5, by_status: { pending: 2, confirmed: 3, completed: 6, cancelled: 1 }, by_payment_method: { cod: 7, online: 5 }, by_payment_status: { pending: 2, successful: 10 }, series: days([2, 0, 10], true) })
    expect(await screen.findByRole('heading', { name: 'Order reports' })).toBeInTheDocument()
    await waitFor(() => expect(within(metric('Orders placed')).getByText('12')).toBeInTheDocument())
    expect(within(metric('Order value')).getByText('₹45,000.50')).toBeInTheDocument()
    expect(within(metric('Pending')).getByText('2')).toBeInTheDocument()
    expect(within(metric('Completed')).getByText('6')).toBeInTheDocument()
    expect(within(metric('Cancelled')).getByText('1')).toBeInTheDocument()
    expect(screen.getByRole('img', { name: 'Orders per day' })).toBeInTheDocument()
    expect(screen.getByText('By payment method')).toBeInTheDocument()
    expect(screen.getByText('Cod')).toBeInTheDocument()
  })

  it('sales report states what a sale is and lists top vendors and products', async () => {
    open('sales', { delivered_orders: 4, gross_sales: 80000, delivery_charges: 200, discounts: 500, commission: 8000, series: days([1, 2, 1], true), by_vendor: [{ vendor_id: 'v-1', vendor_name: 'Alpha Cycles', orders: 3, sales: 60000, commission: 6000 }], by_product: [{ product_id: 'p-1', product_name: 'Trail Blazer', units: 3, sales: 60000 }] })
    await waitFor(() => expect(within(metric('Gross sales')).getByText('₹80,000')).toBeInTheDocument())
    expect(within(metric("Vendors' share")).getByText('₹72,000')).toBeInTheDocument()
    expect(screen.getByText(/A sale is the item value of a vendor order on the day it was delivered/)).toBeInTheDocument()
    expect(within(screen.getByRole('table', { name: 'Top vendors' })).getByText('Alpha Cycles')).toBeInTheDocument()
    expect(within(screen.getByRole('table', { name: 'Top products' })).getByText('Trail Blazer')).toBeInTheDocument()
  })

  it('vendor report: registrations, approvals and performance', async () => {
    open('vendors', { total: 14, new_in_period: 2, by_verification: { approved: 9, pending: 3, suspended: 1, rejected: 1 }, by_account_status: { active: 14 }, series: days([0, 1, 1]), performance: [{ vendor_id: 'v-1', business_name: 'Alpha Cycles', verification_status: 'approved', products: 8, orders_delivered: 5, sales: 42000, bookings_completed: 2 }] })
    await waitFor(() => expect(within(metric('Registered vendors')).getByText('14')).toBeInTheDocument())
    expect(within(metric('Approved')).getByText('9')).toBeInTheDocument()
    expect(within(metric('Suspended')).getByText('1')).toBeInTheDocument()
    const row = (await screen.findByText('Alpha Cycles')).closest('tr') as HTMLElement
    expect(within(row).getByText('₹42,000')).toBeInTheDocument()
  })

  it('customer report: registrations, activity, order and booking activity', async () => {
    open('customers', { total: 120, new_in_period: 7, by_status: { active: 118, restricted: 2 }, active_in_period: 30, orders_in_period: 41, bookings_in_period: 9, series: days([3, 1, 3]), top_customers: [{ customer_id: 'c-1', full_name: 'Asha Rao', orders: 4, order_value: 52000, bookings: 1 }] })
    await waitFor(() => expect(within(metric('Active in period')).getByText('30')).toBeInTheDocument())
    expect(within(metric('Service bookings in period')).getByText('9')).toBeInTheDocument()
    expect(within((await screen.findByText('Asha Rao')).closest('tr') as HTMLElement).getByText('₹52,000')).toBeInTheDocument()
  })

  it('service report: bookings by status, vendor and category, plus pickup and drop-off statistics', async () => {
    open('services', { total: 20, by_status: { pending: 4, completed: 12, cancelled: 3, rejected: 1 }, completed_value: 18000, series: days([5, 5, 10]), by_vendor: [{ vendor_id: 'v-1', vendor_name: 'Alpha Cycles', total: 20, completed: 12, cancelled_or_rejected: 4 }],
      by_category: [{ category_name: 'General Servicing', total: 15 }], pickup: { bookings_needing_pickup: 6, requests: 6, pickup_by_status: { pending: 2, completed: 4 }, delivery_by_status: { pending: 5, scheduled: 1 } } })
    await waitFor(() => expect(within(metric('Bookings')).getByText('20')).toBeInTheDocument())
    expect(within(metric('Completed')).getByText('12')).toBeInTheDocument()
    expect(within(metric('Completed value')).getByText('₹18,000')).toBeInTheDocument()
    expect(within(metric('Bookings needing pickup')).getByText('6')).toBeInTheDocument()
    expect(within(screen.getByRole('table', { name: 'By service category' })).getByText('General Servicing')).toBeInTheDocument()
    expect(screen.getByText('Return delivery status')).toBeInTheDocument()
  })

  it('payment report: collected by method, refunds and commission, with statuses and amounts', async () => {
    open('payments', { total: 9, by_status: { successful: { count: 5, amount: 9000 }, pending: { count: 3, amount: 1500 }, failed: { count: 1, amount: 700 } }, by_method: { online: { count: 6, amount: 8000 }, cod: { count: 3, amount: 3200 } }, collected: 12000,
      collected_by_method: { online: { count: 4, amount: 9000 }, cod: { count: 1, amount: 3000 } }, refunded: 800, refunds_by_status: { processed: { count: 1, amount: 800 } }, commission: 1200, series: days([1, 1, 3], true) })
    await waitFor(() => expect(within(metric('Collected')).getByText('₹12,000')).toBeInTheDocument())
    expect(within(metric('Online collected')).getByText('₹9,000')).toBeInTheDocument()
    expect(within(metric('Cash collected')).getByText('₹3,000')).toBeInTheDocument()
    expect(within(metric('Refunded (processed)')).getByText('₹800')).toBeInTheDocument()
    expect(within(metric('Platform commission')).getByText('₹1,200')).toBeInTheDocument()
    expect(within(screen.getByRole('table', { name: 'Payments by status' })).getByText('Failed')).toBeInTheDocument()
    expect(screen.getByText(/Cash on delivery counts only once an administrator recorded the cash/)).toBeInTheDocument()
  })

  it('an empty period shows real zeros and empty states, never invented numbers', async () => {
    open('sales', { delivered_orders: 0, gross_sales: 0, delivery_charges: 0, discounts: 0, commission: 0, series: days([0, 0, 0], true), by_vendor: [], by_product: [] })
    await waitFor(() => expect(within(metric('Delivered orders')).getByText('0')).toBeInTheDocument())
    expect(screen.getByText('No activity in this period.')).toBeInTheDocument()
    expect(screen.getAllByText('No sales in this period')).toHaveLength(2)
  })

  it('the period controls are sent to the backend, and a reversed period is stopped in the browser', async () => {
    const { backend } = open('orders', { total: 0, value: 0, by_status: {}, by_payment_method: {}, by_payment_status: {}, series: [] })
    await screen.findByRole('heading', { name: 'Order reports' })
    await waitFor(() => expect(backend.calls.find((c) => c.path === '/admin/reports/orders')!.query.get('from')).toMatch(/^\d{4}-\d{2}-\d{2}$/))
    await userEvent.selectOptions(screen.getByLabelText('Quick period'), '7')
    await waitFor(() => {
      const q = backend.calls.filter((c) => c.path === '/admin/reports/orders').at(-1)!.query
      expect((new Date(q.get('to')!).getTime() - new Date(q.get('from')!).getTime()) / 86_400_000).toBe(6)
    })
    fireEvent.change(screen.getByLabelText('From'), { target: { value: '2026-03-10' } })
    await waitFor(() => expect(backend.calls.filter((c) => c.path === '/admin/reports/orders').at(-1)!.query.get('from')).toBe('2026-03-10'))
    const before = backend.count('GET', '/admin/reports/orders')
    fireEvent.change(screen.getByLabelText('To'), { target: { value: '2026-03-01' } })
    expect(await screen.findAllByText('The start date must not be after the end date.')).not.toHaveLength(0)
    expect(backend.count('GET', '/admin/reports/orders')).toBeLessThanOrEqual(before + 1)
  })

  it('a failing report shows the backend\'s message with a retry, and the page keeps working', async () => {
    renderApp({ path: '/reports/orders', gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), 'GET /admin/reports/orders': err(422, 'range_too_long', 'Choose a period of at most 366 days.') } as never })
    expect(await screen.findByText('Choose a period of at most 366 days.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Order reports' })).toBeInTheDocument()
  })

  it('/reports opens the sales report', async () => {
    const { router } = open('sales', { delivered_orders: 0, gross_sales: 0, delivery_charges: 0, discounts: 0, commission: 0, series: [], by_vendor: [], by_product: [] }, '/reports')
    await screen.findByRole('heading', { name: 'Sales reports' })
    expect(router.state.location.pathname).toBe('/reports/sales')
  })
})
