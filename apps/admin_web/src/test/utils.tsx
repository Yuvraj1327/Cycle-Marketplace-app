import { render } from '@testing-library/react'
import { RouterProvider } from 'react-router-dom'
import { vi } from 'vitest'
import { AuthProvider } from '../app/providers/AuthProvider'
import { ToastProvider } from '../app/providers/ToastProvider'
import { createTestRouter } from '../app/router'
import { AuthFailure, type AuthGateway } from '../services/supabase/gateway'

export interface FakeGateway extends AuthGateway {
  token: string | null
  signInCalls: number
  signOutCalls: number
  listeners: ((s: boolean) => void)[]
  failSignInWith: string | null
  refreshTo: string | null
  changed: { current: string; next: string }[]
}

export function fakeGateway(opts: { token?: string | null; failSignInWith?: string; refreshTo?: string | null } = {}): FakeGateway {
  const g: FakeGateway = {
    token: opts.token ?? null,
    signInCalls: 0,
    signOutCalls: 0,
    listeners: [],
    failSignInWith: opts.failSignInWith ?? null,
    refreshTo: opts.refreshTo ?? null,
    changed: [],
    async getAccessToken() { return g.token },
    async refresh() { g.token = g.refreshTo; return g.refreshTo },
    onChange(cb) { g.listeners.push(cb); return () => { g.listeners = g.listeners.filter((l) => l !== cb) } },
    async signIn() {
      g.signInCalls++
      await new Promise((r) => setTimeout(r, 5))
      if (g.failSignInWith) throw new AuthFailure(g.failSignInWith)
      g.token = 'tok-admin'
      g.listeners.forEach((l) => l(true))
    },
    async signOut() { g.signOutCalls++; g.token = null; g.listeners.forEach((l) => l(false)) },
    async sendPasswordReset() {},
    async changePassword(_e, current, next) { g.changed.push({ current, next }) },
  }
  return g
}

export interface RecordedCall { method: string; path: string; query: URLSearchParams; body: unknown; auth: string | null }
type Handler = (c: RecordedCall) => { status?: number; body?: unknown } | undefined

/** A fake `fetch` answering from a route table (`'GET /admin/customers'`); every request is recorded. Unmatched requests fail loudly. */
export function fakeBackend(routes: Record<string, Handler | { status?: number; body?: unknown }>) {
  const calls: RecordedCall[] = []
  const impl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input))
    const call: RecordedCall = {
      method: (init?.method ?? 'GET').toUpperCase(),
      path: url.pathname.replace('/api/v1', ''),
      query: url.searchParams,
      body: init?.body ? JSON.parse(String(init.body)) : undefined,
      auth: (init?.headers as Record<string, string> | undefined)?.Authorization ?? null,
    }
    calls.push(call)
    const key = Object.keys(routes).find((k) => k === `${call.method} ${call.path}`) ?? Object.keys(routes).find((k) => {
      const [m, p] = k.split(' ')
      return m === call.method && new RegExp(`^${p.replace(/:[a-z]+/g, '[^/]+')}$`).test(call.path)
    })
    if (!key) throw new Error(`Unexpected request: ${call.method} ${call.path}`)
    const r = routes[key]
    const out = (typeof r === 'function' ? r(call) : r) ?? { body: {} }
    return new Response(out.status === 204 ? null : JSON.stringify(out.body ?? {}), { status: out.status ?? 200, headers: { 'Content-Type': 'application/json' } })
  })
  return { fetch: impl as unknown as typeof fetch, calls, count: (m: string, p: string) => calls.filter((c) => c.method === m && c.path === p).length }
}

export const err = (status: number, code: string, message: string) => ({ status, body: { error: { code, message } } })

export const me = (role = 'admin', status = 'active') => ({
  id: 'u-1', email: 'root@example.com', phone: null, role, status, vendor_verification_status: null,
  session: { session_id: 's', assurance_level: 'aal1', token_expires_at: '2030-01-01T00:00:00Z' },
  profile: { id: 'u-1', full_name: 'Root Admin', email: 'root@example.com', phone: null, role, status, avatar_path: null, created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z' },
})

export const page = <T,>(items: T[], extra: Partial<{ total: number; page: number; pages: number; limit: number }> = {}) => ({
  items, total: extra.total ?? items.length, page: extra.page ?? 1, limit: extra.limit ?? 20, pages: extra.pages ?? (items.length ? 1 : 0),
})

export const customer = (n: number, over: Record<string, unknown> = {}) => ({
  id: `c-${n}`, full_name: `Customer ${n}`, email: `c${n}@example.com`, phone: `+9198000000${n}`, status: 'active', created_at: '2026-02-01T10:00:00Z', order_count: n, booking_count: 0, ...over,
})

export const vendor = (n: number, over: Record<string, unknown> = {}) => ({
  id: `v-${n}`, user_id: `vu-${n}`, business_name: `Shop ${n}`, owner_name: `Owner ${n}`, owner_email: `o${n}@shop.test`, contact_phone: '+919811100000', contact_email: null,
  business_types: ['bicycle_shop'], city: 'Pune', state: 'MH', verification_status: 'pending', account_status: 'active', created_at: '2026-02-02T10:00:00Z',
  product_count: 0, order_count: 0, booking_count: 0, ...over,
})

export const dashboard = (over: Record<string, unknown> = {}) => ({
  period: { from: '2026-02-01', to: '2026-02-03' },
  customers: { total: 120, by_status: { active: 118, restricted: 2 }, new_in_period: 7 },
  vendors: { total: 14, by_verification: { approved: 9, pending: 3, suspended: 1, rejected: 1 }, by_account_status: { active: 14 }, new_in_period: 2 },
  orders: { total: 56, by_status: { pending: 4, confirmed: 10, completed: 38, cancelled: 4 }, value_completed: 123456.5, value_confirmed: 20000 },
  bookings: { total: 21, by_status: { pending: 5, completed: 16 } },
  series: {
    orders: [{ day: '2026-02-01', count: 2, value: 1000 }, { day: '2026-02-02', count: 0, value: 0 }, { day: '2026-02-03', count: 5, value: 5000 }],
    bookings: [{ day: '2026-02-01', count: 1 }, { day: '2026-02-02', count: 0 }, { day: '2026-02-03', count: 2 }],
    customers: [{ day: '2026-02-01', count: 3 }, { day: '2026-02-02', count: 1 }, { day: '2026-02-03', count: 3 }],
    vendors: [{ day: '2026-02-01', count: 0 }, { day: '2026-02-02', count: 1 }, { day: '2026-02-03', count: 1 }],
  },
  ...over,
})

export const payments = () => ({ period_from: '2026-02-01T00:00:00Z', period_to: '2026-02-03T00:00:00Z', collected: 90000, refunded: 1500, net_collected: 88500, commission_earned: 9000, cod_outstanding: 2500, orders_placed: 56, orders_completed: 38, settlements: {} })

/** Backend answers every admin console screen needs at start-up. */
export const baseRoutes = (role = 'admin', status = 'active'): Record<string, Handler | { status?: number; body?: unknown }> => ({
  'GET /auth/me': { body: me(role, status) },
  'POST /auth/logout': { body: {} },
  'GET /admin/dashboard': { body: dashboard() },
  'GET /admin/payments/summary': { body: payments() },
  'GET /admin/customers': { body: page([customer(1), customer(2)]) },
  'GET /admin/vendors': { body: page([vendor(1)]) },
  'GET /admin/orders': { body: page([]) },
  'GET /admin/service-bookings': { body: page([]) },
})

export function renderApp(opts: { path?: string; gateway?: FakeGateway; routes: Record<string, Handler | { status?: number; body?: unknown }> }) {
  const gateway = opts.gateway ?? fakeGateway({ token: 'tok-admin' })
  const backend = fakeBackend(opts.routes)
  const router = createTestRouter([opts.path ?? '/'])
  const utils = render(
    <ToastProvider>
      <AuthProvider gateway={gateway} apiBaseUrl="http://api.test" fetchImpl={backend.fetch}>
        <RouterProvider router={router} />
      </AuthProvider>
    </ToastProvider>,
  )
  return { ...utils, gateway, backend, router }
}
