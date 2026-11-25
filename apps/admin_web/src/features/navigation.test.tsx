import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { NAV_GROUPS } from '../components/layout/nav'
import { baseRoutes, fakeGateway, page, renderApp } from '../test/utils'

const EXPECTED: Record<string, string[]> = {
  Main: ['Overview', 'Customers', 'Vendors'],
  Marketplace: ['Products', 'Categories', 'Featured Products', 'Promotional Banners'],
  Operations: ['Orders', 'Services', 'Service Categories', 'Service Bookings', 'Pickup & Drop-Off'],
  Finance: ['Payments', 'Refunds', 'Commission Management', 'Vendor Settlements'],
  Communication: ['Notifications', 'Announcements'],
  Reports: ['Sales Reports', 'Order Reports', 'Vendor Reports', 'Customer Reports', 'Service Reports', 'Payment Reports'],
  Settings: ['Platform Settings', 'Pickup and Delivery Charges', 'Offers and Coupons', 'Account Settings'],
}

// every GET answers with an empty page; list-shaped endpoints that return arrays answer with []
const fallback = (c: { path: string }) => ({ body: /\/(categories|service-categories|banners|commission-rules|settings)$/.test(c.path) ? [] : c.path.includes('/reports/') ? { kind: 'orders', period_from: '', period_to: '', timezone: 'Asia/Kolkata', data: { total: 0, value: 0, by_status: {}, by_payment_method: {}, by_payment_status: {}, series: [], by_vendor: [], by_product: [], performance: [], top_customers: [], by_category: [], pickup: { bookings_needing_pickup: 0, requests: 0, pickup_by_status: {}, delivery_by_status: {} }, new_in_period: 0, by_verification: {}, by_account_status: {},  collected: 0, collected_by_method: {}, by_method: {}, refunded: 0, refunds_by_status: {}, commission: 0, completed_value: 0, active_in_period: 0, orders_in_period: 0, bookings_in_period: 0, delivered_orders: 0, gross_sales: 0, delivery_charges: 0, discounts: 0 } } : { ...page([]), summary: {} } })

describe('navigation', () => {
  it('the sidebar has exactly the specified sections and links, in order, on every page', async () => {
    renderApp({ gateway: fakeGateway({ token: 'tok' }), routes: baseRoutes() })
    await screen.findByRole('heading', { name: 'Overview' })
    const nav = screen.getByRole('navigation', { name: 'Main navigation' })
    expect(within(nav).getAllByRole('group').map((g) => g.getAttribute('aria-label'))).toEqual(Object.keys(EXPECTED))
    for (const [heading, labels] of Object.entries(EXPECTED)) {
      const group = within(nav).getByRole('group', { name: heading })
      expect(within(group).getAllByRole('link').map((a) => a.textContent)).toEqual(labels)
    }
    expect(within(nav).queryByText('Soon')).not.toBeInTheDocument()
  })

  it('highlights the active section and keeps the sidebar available on a deep page', async () => {
    renderApp({ path: '/reports/payments', gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), 'GET *': fallback } as never })
    await screen.findByRole('heading', { name: 'Payment reports' })
    const nav = screen.getByRole('navigation', { name: 'Main navigation' })
    expect(within(nav).getByRole('link', { name: 'Payment Reports' })).toHaveClass('active')
    expect(within(nav).getByRole('link', { name: 'Sales Reports' })).not.toHaveClass('active')
    expect(within(nav).getByRole('link', { name: 'Overview' })).not.toHaveClass('active')
  })

  it('every sidebar link opens a real page (no placeholder, no 404) behind the admin guard', async () => {
    for (const item of NAV_GROUPS.flatMap((g) => g.items)) {
      const { unmount } = renderApp({ path: item.to, gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), 'GET *': fallback } as never })
      expect(await screen.findByRole('heading', { level: 1 }), item.to).toBeInTheDocument()
      expect(screen.queryByText('Page not found'), item.to).not.toBeInTheDocument()
      expect(screen.queryByText(/Unexpected Application Error/i), item.to).not.toBeInTheDocument()
      expect(screen.queryByText(/coming next|Nothing here is functional/i), item.to).not.toBeInTheDocument()
      unmount()
    }
  })

  it('the mobile menu button opens the sidebar and a link closes it', async () => {
    renderApp({ gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), 'GET *': fallback } as never })
    await screen.findByRole('heading', { name: 'Overview' })
    const button = screen.getByRole('button', { name: 'Open menu' })
    expect(button).toHaveAttribute('aria-expanded', 'false')
    await userEvent.click(button)
    expect(button).toHaveAttribute('aria-expanded', 'true')
    await userEvent.click(within(screen.getByRole('navigation', { name: 'Main navigation' })).getByRole('link', { name: 'Refunds' }))
    expect(await screen.findByRole('heading', { name: 'Refunds' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Open menu' })).toHaveAttribute('aria-expanded', 'false')
  })

  it('breadcrumbs lead back to the overview', async () => {
    renderApp({ path: '/settings/coupons', gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), 'GET *': fallback } as never })
    await screen.findByRole('heading', { name: 'Offers and coupons' })
    const crumbs = screen.getByRole('navigation', { name: 'Breadcrumb' })
    expect(within(crumbs).getByRole('link', { name: 'Overview' })).toHaveAttribute('href', '/')
    expect(within(crumbs).getByRole('link', { name: 'Settings' })).toHaveAttribute('href', '/settings')
  })
})
