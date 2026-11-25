import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { baseRoutes, customer, err, fakeGateway, me, page, renderApp } from '../../test/utils'

describe('admin authentication & route protection', () => {
  it('an unauthenticated visitor is redirected to the login page, from any private URL', async () => {
    for (const path of ['/', '/customers', '/vendors/abc', '/profile']) {
      const { router, backend, unmount } = renderApp({ path, gateway: fakeGateway(), routes: baseRoutes() })
      expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
      expect(router.state.location.pathname).toBe('/login')
      expect(backend.calls).toHaveLength(0)           // no API call is made without a session
      unmount()
    }
  })

  it('shows validation messages and does not contact the identity provider for bad input', async () => {
    const { gateway } = renderApp({ gateway: fakeGateway(), routes: baseRoutes() })
    await userEvent.click(await screen.findByRole('button', { name: 'Sign in' }))
    expect(await screen.findByText('Enter a valid e-mail address.')).toBeInTheDocument()
    expect(screen.getByText('Enter your password.')).toBeInTheDocument()
    expect(gateway.signInCalls).toBe(0)
  })

  it('wrong credentials show the provider message and allow another try', async () => {
    const { gateway } = renderApp({ gateway: fakeGateway({ failSignInWith: 'Incorrect e-mail or password.' }), routes: baseRoutes() })
    await userEvent.type(await screen.findByLabelText('E-mail'), 'root@example.com')
    await userEvent.type(screen.getByLabelText('Password'), 'wrong-password')
    await userEvent.click(screen.getByRole('button', { name: 'Sign in' }))
    expect(await screen.findByText('Incorrect e-mail or password.')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Sign in' }))
    await waitFor(() => expect(gateway.signInCalls).toBe(2))
  })

  it('password visibility can be toggled', async () => {
    renderApp({ gateway: fakeGateway(), routes: baseRoutes() })
    const pw = await screen.findByLabelText('Password')
    expect(pw).toHaveAttribute('type', 'password')
    await userEvent.click(screen.getByRole('button', { name: 'Show password' }))
    expect(pw).toHaveAttribute('type', 'text')
  })

  it('an administrator signs in: the BACKEND is asked who they are, with the Bearer token, then the dashboard opens', async () => {
    const { backend, gateway } = renderApp({ gateway: fakeGateway(), routes: baseRoutes() })
    await userEvent.type(await screen.findByLabelText('E-mail'), 'root@example.com')
    await userEvent.type(screen.getByLabelText('Password'), 'Secret123')
    await userEvent.click(screen.getByRole('button', { name: 'Sign in' }))
    expect(await screen.findByRole('heading', { name: 'Overview' })).toBeInTheDocument()
    const whoami = backend.calls.find((c) => c.path === '/auth/me')!
    expect(whoami.auth).toBe('Bearer tok-admin')
    expect(gateway.signOutCalls).toBe(0)
  })

  it.each([['customer', 'active'], ['vendor', 'active']])('a %s account is refused: signed out, told why, and no admin data is requested', async (role, status) => {
    const routes = baseRoutes(role, status)
    const { backend, gateway } = renderApp({ gateway: fakeGateway(), routes })
    await userEvent.type(await screen.findByLabelText('E-mail'), 'someone@example.com')
    await userEvent.type(screen.getByLabelText('Password'), 'Secret123')
    await userEvent.click(screen.getByRole('button', { name: 'Sign in' }))
    expect(await screen.findByText(/not an administrator/i)).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    expect(gateway.signOutCalls).toBe(1)
    expect(backend.calls.filter((c) => c.path.startsWith('/admin'))).toHaveLength(0)
  })

  it('a suspended/inactive administrator is refused', async () => {
    renderApp({ gateway: fakeGateway({ token: 'tok' }), routes: baseRoutes('admin', 'inactive') })
    expect(await screen.findByText(/administrator account is inactive/i)).toBeInTheDocument()
  })

  it('an existing session is restored on refresh without asking for credentials', async () => {
    const { router, backend } = renderApp({ path: '/customers', gateway: fakeGateway({ token: 'tok-admin' }), routes: baseRoutes() })
    expect(await screen.findByRole('heading', { name: 'Customers' })).toBeInTheDocument()
    expect(router.state.location.pathname).toBe('/customers')
    expect(backend.count('GET', '/auth/me')).toBe(1)
  })

  it('role stored in the browser is never trusted: a forged local-storage role cannot open the console', async () => {
    localStorage.setItem('role', 'admin')
    localStorage.setItem('admin', 'true')
    renderApp({ gateway: fakeGateway({ token: 'tok-customer' }), routes: baseRoutes('customer') })
    expect(await screen.findByText(/not an administrator/i)).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Overview' })).not.toBeInTheDocument()
    localStorage.clear()
  })

  it('an expired token on restore returns to login with a clear message', async () => {
    renderApp({ gateway: fakeGateway({ token: 'expired' }), routes: { ...baseRoutes(), 'GET /auth/me': err(401, 'token_expired', 'Your session has expired.') } })
    expect(await screen.findByText(/session has expired/i)).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })

  it('the session expiring while using the console signs the admin out', async () => {
    let expired = false
    const { gateway } = renderApp({ gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), 'GET /admin/customers': () => (expired ? err(401, 'token_expired', 'expired') : { body: page([customer(1)]) }) } })
    await screen.findByRole('heading', { name: 'Overview' })
    expired = true
    await userEvent.click(screen.getAllByRole('link', { name: 'Customers' })[0])
    expect(await screen.findByText(/session has expired/i)).toBeInTheDocument()
    expect(gateway.signOutCalls).toBeGreaterThan(0)
  })

  it('losing admin rights mid-session (backend 403) shows Access denied and keeps the admin pages closed', async () => {
    renderApp({ gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), 'GET /admin/customers': err(403, 'permission_denied', 'Your role is not allowed to perform this action.') } })
    expect(await screen.findByRole('heading', { name: 'Access denied' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Overview' })).not.toBeInTheDocument()
  })

  it('logout asks for confirmation, calls the backend, signs out of the provider and returns to login', async () => {
    const { backend, gateway } = renderApp({ gateway: fakeGateway({ token: 'tok' }), routes: baseRoutes() })
    await screen.findByRole('heading', { name: 'Overview' })
    await userEvent.click(screen.getByRole('button', { name: /Root Admin/ }))
    await userEvent.click(screen.getByRole('menuitem', { name: 'Sign out' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Sign out' }))
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    expect(backend.count('POST', '/auth/logout')).toBe(1)
    expect(gateway.signOutCalls).toBe(1)
    expect(gateway.token).toBeNull()
  })

  it('an unknown admin address shows a not-found page, not a blank screen', async () => {
    renderApp({ path: '/no-such-module', gateway: fakeGateway({ token: 'tok' }), routes: baseRoutes() })
    expect(await screen.findByText('Page not found')).toBeInTheDocument()
  })

  it('me() identity helper sanity', () => expect(me().role).toBe('admin'))
})
