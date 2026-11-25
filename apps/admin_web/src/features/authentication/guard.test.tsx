import { screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { NAV_GROUPS } from '../../components/layout/nav'
import { baseRoutes, err, fakeGateway, renderApp } from '../../test/utils'

const DETAIL_ROUTES = ['/products/p-1', '/orders/o-1', '/orders/fulfilment', '/service-bookings/bk-1', '/payments/pay-1', '/customers/c-1', '/vendors/v-1']
const ALL = [...NAV_GROUPS.flatMap((g) => g.items.map((i) => i.to)), ...DETAIL_ROUTES]

describe('every administrative page is behind the admin guard', () => {
  it('signed-out visitors are sent to the sign-in page and no admin API is ever called', async () => {
    for (const path of ALL) {
      const { backend, unmount } = renderApp({ path, gateway: fakeGateway({ token: null }), routes: baseRoutes() })
      expect(await screen.findByRole('heading', { name: 'Sign in' }), path).toBeInTheDocument()
      expect(backend.calls.filter((c) => c.path.startsWith('/admin')), path).toHaveLength(0)
      unmount()
    }
  })

  it('a signed-in customer or vendor is refused by the backend verdict and never reaches an admin API', async () => {
    for (const role of ['customer', 'vendor']) {
      for (const path of ['/payments', '/orders', '/settings/coupons', '/reports/sales', '/announcements']) {
        const { backend, unmount, gateway } = renderApp({ path, gateway: fakeGateway({ token: 'tok' }), routes: baseRoutes(role) })
        expect(await screen.findByText(/not an administrator/i), `${role} ${path}`).toBeInTheDocument()
        expect(backend.calls.filter((c) => c.path.startsWith('/admin')), `${role} ${path}`).toHaveLength(0)
        expect(gateway.signOutCalls).toBeGreaterThan(0)
        unmount()
      }
    }
  })

  it('an inactive administrator is refused too', async () => {
    const { backend } = renderApp({ path: '/refunds', gateway: fakeGateway({ token: 'tok' }), routes: baseRoutes('admin', 'inactive') })
    expect(await screen.findByText(/administrator account is inactive/i)).toBeInTheDocument()
    expect(backend.calls.filter((c) => c.path.startsWith('/admin'))).toHaveLength(0)
  })

  it('losing admin rights while a Step 10 page is open (backend 403) closes every admin page', async () => {
    renderApp({ path: '/payments', gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), 'GET /admin/payments': err(403, 'permission_denied', 'Your role is not allowed to perform this action.'), 'GET /admin/reports/payments': err(403, 'permission_denied', 'no'), 'GET /admin/payments/summary': err(403, 'permission_denied', 'no') } })
    expect(await screen.findByRole('heading', { name: 'Access denied' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Payments' })).not.toBeInTheDocument()
  })

  it('an expired session on a Step 10 page returns to sign-in', async () => {
    renderApp({ path: '/orders', gateway: fakeGateway({ token: 'tok', refreshTo: null }), routes: { ...baseRoutes(), 'GET /admin/orders': err(401, 'invalid_token', 'The access token has expired.') } })
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })
})
