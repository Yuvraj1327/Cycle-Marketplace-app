import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { baseRoutes, customer, dashboard, err, fakeGateway, page, renderApp, vendor } from '../../test/utils'

const open = (routes = baseRoutes()) => renderApp({ gateway: fakeGateway({ token: 'tok' }), routes })

describe('dashboard', () => {
  it('shows the statistics returned by the backend (nothing hardcoded)', async () => {
    const { backend } = open({ ...baseRoutes(), 'GET /admin/dashboard': { body: dashboard({ customers: { total: 4321, by_status: { active: 4321 }, new_in_period: 12 }, vendors: { total: 77, by_verification: { approved: 60, pending: 9, suspended: 2 }, by_account_status: {}, new_in_period: 3 } }) } })
    const card = async (label: string) => (await screen.findByText((_, el) => !!el?.classList.contains('metric-label') && el.textContent === label)).closest('.metric') as HTMLElement
    expect(within(await card('Customers')).getByText('4.3K')).toBeInTheDocument()
    expect(within(await card('Pending vendor approvals')).getByText('9')).toBeInTheDocument()
    expect(within(await card('Approved vendors')).getByText('60')).toBeInTheDocument()
    expect(within(await card('Suspended vendors')).getByText('2')).toBeInTheDocument()
    expect(within(await card('Pending orders')).getByText('4')).toBeInTheDocument()
    expect(within(await card('Completed orders')).getByText('38')).toBeInTheDocument()
    expect(within(await card('Cancelled orders')).getByText('4')).toBeInTheDocument()
    expect(within(await card('Service bookings')).getByText('21')).toBeInTheDocument()
    expect(await screen.findByText('₹88,500')).toBeInTheDocument()            // net collected from /admin/payments/summary
    const q = backend.calls.find((c) => c.path === '/admin/dashboard')!.query
    expect(q.get('from')).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    expect(q.get('to')).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })

  it('all-zero data renders proper empty states instead of fake numbers or charts', async () => {
    const zero = dashboard({
      customers: { total: 0, by_status: {}, new_in_period: 0 }, vendors: { total: 0, by_verification: {}, by_account_status: {}, new_in_period: 0 },
      orders: { total: 0, by_status: {}, value_completed: 0, value_confirmed: 0 }, bookings: { total: 0, by_status: {} },
      series: { orders: [{ day: '2026-02-01', count: 0, value: 0 }], bookings: [{ day: '2026-02-01', count: 0 }], customers: [{ day: '2026-02-01', count: 0 }], vendors: [{ day: '2026-02-01', count: 0 }] },
    })
    open({ ...baseRoutes(), 'GET /admin/dashboard': { body: zero }, 'GET /admin/customers': { body: page([]) }, 'GET /admin/vendors': { body: page([]) } })
    expect(await screen.findAllByText('No activity in this period.')).toHaveLength(5)
    expect(screen.getByText('No records yet.')).toBeInTheDocument()
    expect(await screen.findByText('No pending applications')).toBeInTheDocument()
    expect(await screen.findByText('No customers yet')).toBeInTheDocument()
  })

  it('charts plot only the returned per-day values', async () => {
    open()
    const chart = (await screen.findByRole('img', { name: 'Orders placed' })).closest('figure') as HTMLElement
    expect(within(chart).getByText(/total 7/)).toBeInTheDocument()            // 2 + 0 + 5 from the backend series
    expect(chart.querySelectorAll('rect')).toHaveLength(3)
  })

  it('an API failure shows an error with Try again; recovery loads the data', async () => {
    let fail = true
    open({ ...baseRoutes(), 'GET /admin/dashboard': () => (fail ? err(500, 'internal_error', 'An unexpected error occurred.') : { body: dashboard() }) })
    expect(await screen.findByText('Something went wrong')).toBeInTheDocument()
    fail = false
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Total orders')).toBeInTheDocument()
  })

  it('a failing side panel does not blank the page', async () => {
    open({ ...baseRoutes(), 'GET /admin/payments/summary': err(503, 'unavailable', 'Payments are unavailable.') })
    expect(await screen.findByText('Total orders')).toBeInTheDocument()
    expect(await screen.findByText('Payments are unavailable.')).toBeInTheDocument()
  })

  it('lists recent customers, vendors and pending approvals with links to management pages', async () => {
    open({
      ...baseRoutes(),
      'GET /admin/customers': { body: page([customer(1, { full_name: 'Asha Rao' })]) },
      'GET /admin/vendors': (c) => ({ body: page([c.query.get('verification_status') === 'pending' ? vendor(5, { business_name: 'Pending Cycles' }) : vendor(1, { business_name: 'Spoke & Co', verification_status: 'approved' })]) }),
    })
    expect(await screen.findByRole('link', { name: /Asha Rao/ })).toHaveAttribute('href', '/customers/c-1')
    expect(await screen.findByRole('link', { name: /Pending Cycles/ })).toHaveAttribute('href', '/vendors/v-5')
    expect(await screen.findByRole('link', { name: /Spoke & Co/ })).toHaveAttribute('href', '/vendors/v-1')
    expect(screen.getByRole('link', { name: 'Approve vendor registrations' })).toHaveAttribute('href', '/vendors?verification_status=pending')
  })
})
