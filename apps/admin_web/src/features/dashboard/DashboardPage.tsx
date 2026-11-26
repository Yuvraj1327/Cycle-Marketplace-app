import { useMemo, useState, type ReactNode } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth, useServices } from '../../app/providers/authContext'
import bannerImage from '../../assets/dashboard-banner.jpg'
import { AreaChart, DailyBars, Donut } from '../../components/charts/charts'
import { Button, Card, EmptyState, ErrorState, MetricCard, PageLoading, StatusBadge } from '../../components/common/ui'
import { I } from '../../components/layout/nav'
import { useAsync, type AsyncState } from '../../hooks/useAsync'
import { ApiError } from '../../services/api/client'
import { compactNumber, dateOnly, dateTime, initials, isoDay, money } from '../../utils/format'

const RANGES = [{ days: 7, label: 'Last 7 days' }, { days: 30, label: 'Last 30 days' }, { days: 90, label: 'Last 90 days' }]

function period(days: number): { from: string; to: string } {
  const to = new Date()
  const from = new Date()
  from.setDate(to.getDate() - (days - 1))
  return { from: isoDay(from), to: isoDay(to) }
}

function Icon({ d, size = 20 }: { d: string; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>
  )
}

const REFRESH = 'M21 12a9 9 0 1 1-3-6.7L21 8M21 3v5h-5'
const CLOCK = 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-14v5l3 2'
const BOLT = 'M13 2 4 14h7l-1 8 9-12h-7l1-8Z'
const PULSE = 'M3 12h4l3-8 4 16 3-8h4'
const CHECK = 'M20 6 9 17l-5-5'
const CHEVRON = 'm9 6 6 6-6 6'

type Tint = 'green' | 'blue' | 'purple' | 'orange'

/** One headline statistic. Keeps the `metric` / `metric-label` / `metric-value` structure the rest of the app and its tests rely on. */
function StatTile({ label, value, hint, hintTone, to, icon, tint, ghost = true }: { label: string; value: ReactNode; hint: ReactNode; hintTone?: 'up'; to: string; icon: string; tint: Tint; ghost?: boolean }) {
  return (
    <Link to={to} className={`card metric metric-link stat-tile tint-${tint}`}>
      <span className="stat-icon" aria-hidden="true"><Icon d={icon} size={22} /></span>
      <div className="stat-body">
        <span className="metric-label">{label}</span>
        <div className="metric-value">{value}</div>
        <div className={`metric-hint ${hintTone === 'up' ? 'hint-up' : ''}`}>{hint}</div>
      </div>
      {ghost && <span className="stat-ghost" aria-hidden="true"><Icon d={icon} size={64} /></span>}
    </Link>
  )
}

/** Shared body of a recent-activity card: error, loading, empty or the list. */
function Panel<T>({ q, empty, children }: { q: AsyncState<{ items: T[] }>; empty: ReactNode; children: (items: T[]) => ReactNode }) {
  if (q.error) return <ErrorState compact error={q.error} onRetry={q.reload} />
  if (q.loading && !q.data) return <PageLoading />
  if (!q.data || q.data.items.length === 0) return <>{empty}</>
  return <>{children(q.data.items)}</>
}

type Health = { label: string; ok: boolean | null; text: string }

export function DashboardPage() {
  const s = useServices()
  const { me } = useAuth()
  const nav = useNavigate()
  const [days, setDays] = useState(30)
  const [metric, setMetric] = useState<'orders' | 'value'>('orders')
  const range = useMemo(() => period(days), [days])
  // reload everything together; each block has its own error state so one failing request never blanks the page
  const summary = useAsync(() => s.dashboard.summary(range.from, range.to), [range.from, range.to])
  const payments = useAsync(() => s.dashboard.payments(range.from, range.to), [range.from, range.to])
  const customers = useAsync(() => s.customers.list({ limit: 5, sort: 'newest' }), [])
  const vendors = useAsync(() => s.vendors.list({ limit: 5, sort: 'newest' }), [])
  const pending = useAsync(() => s.vendors.list({ limit: 5, verification_status: 'pending', sort: 'oldest' }), [])
  const orders = useAsync(() => s.dashboard.recentOrders(5), [])
  const bookings = useAsync(() => s.dashboard.recentBookings(5), [])

  const refresh = () => [summary, payments, customers, vendors, pending, orders, bookings].forEach((q) => q.reload())
  const d = summary.data
  const firstName = (me?.profile.full_name ?? '').trim().split(/\s+/)[0] || 'Admin'

  const pendingVendors = d?.vendors.by_verification.pending ?? 0
  const pendingBookings = d?.bookings.by_status.pending ?? 0
  const byStatus = d?.orders.by_status ?? {}
  const statusSlices = [
    { label: 'Completed', value: byStatus.completed ?? 0, color: 'var(--c-green)' },
    { label: 'Pending', value: byStatus.pending ?? 0, color: '#e2a727' },
    { label: 'In Progress', value: byStatus.confirmed ?? 0, color: 'var(--c-blue)' },
    { label: 'Cancelled', value: byStatus.cancelled ?? 0, color: 'var(--c-red)' },
  ]
  const known = statusSlices.reduce((n, x) => n + x.value, 0)
  if (d && d.orders.total > known) statusSlices.push({ label: 'Other', value: d.orders.total - known, color: 'var(--c-muted)' })

  // Platform health is read from this page's own live requests, never assumed.
  const offline = [summary, payments, customers, vendors].every((q) => q.error instanceof ApiError && q.error.isNetwork)
  const health: Health[] = [
    { label: 'Database', ok: summary.data ? true : summary.error ? false : null, text: summary.data ? 'Online' : summary.error ? 'Unavailable' : 'Checking…' },
    { label: 'Server', ok: offline ? false : summary.data || payments.data || customers.data || vendors.data ? true : summary.loading ? null : false, text: offline ? 'Offline' : summary.data || payments.data || customers.data || vendors.data ? 'Online' : summary.loading ? 'Checking…' : 'Unavailable' },
    { label: 'Payments', ok: payments.data ? true : payments.error ? false : null, text: payments.data ? 'Ready' : payments.error ? 'Unavailable' : 'Checking…' },
  ]

  return (
    <div className="dash">
      <div className="dash-head">
        <div>
          <h1>Welcome back, {firstName}! <span aria-hidden="true">👋</span></h1>
          <p className="muted">Manage your cycle marketplace, vendors, orders and services from one place.</p>
        </div>
        <div className="page-actions">
          <label className="period">
            <Icon d={I.calendar} size={18} />
            <select aria-label="Period" value={days} onChange={(e) => setDays(Number(e.target.value))}>
              {RANGES.map((r) => <option key={r.days} value={r.days}>{r.label}</option>)}
            </select>
          </label>
          <Button onClick={refresh}><Icon d={REFRESH} size={16} />Refresh</Button>
        </div>
      </div>

      <div className="dash-banner">
        <img src={bannerImage} width={2172} height={724} alt="Cycle Marketplace: buy cycles, get parts and book repair services. Marketplace, service booking, pickup and drop-off." />
      </div>

      {summary.loading && !d && <PageLoading label="Loading dashboard…" />}
      {summary.error && !d && <ErrorState error={summary.error} onRetry={summary.reload} />}

      {d && (
        <div className="stat-row">
          <StatTile label="Customers" value={compactNumber(d.customers.total)} to="/customers" icon={I.people} tint="green"
            hint={d.customers.new_in_period > 0 ? `↑ +${d.customers.new_in_period} new` : 'No new customers'} hintTone={d.customers.new_in_period > 0 ? 'up' : undefined} />
          <StatTile label="Vendors" value={compactNumber(d.vendors.total)} to="/vendors" icon={I.store} tint="blue"
            hint={d.vendors.new_in_period > 0 ? `↑ +${d.vendors.new_in_period} new` : 'No new vendors'} hintTone={d.vendors.new_in_period > 0 ? 'up' : undefined} />
          <StatTile label="Service bookings" value={compactNumber(d.bookings.total)} to="/service-bookings" icon={I.calendar} tint="purple"
            hint={d.bookings.total === 0 ? 'No bookings' : `${pendingBookings} pending`} />
          <StatTile label="Total orders" value={compactNumber(d.orders.total)} to="/orders" icon={I.box} tint="orange"
            hint={d.orders.total === 0 ? 'No orders' : `${byStatus.pending ?? 0} pending`} />
          <StatTile label="Order value" value={money(d.orders.value_completed)} to="/orders" icon="M6 4h12M6 9h12M9 4c5 0 7 2 7 5s-2 5-7 5h-1l8 6" tint="green" ghost={false}
            hint={d.orders.value_completed === 0 && d.orders.value_confirmed === 0 ? 'No order value yet' : `${money(d.orders.value_confirmed)} in progress`} />
        </div>
      )}

      <div className="dash-main">
        {d && (
          <>
            <Card className="area-card" title={<><span className="card-icon"><Icon d={I.box} size={18} /></span>Orders overview</>}
              actions={
                <div className="seg" role="group" aria-label="Chart data">
                  <button type="button" aria-pressed={metric === 'orders'} onClick={() => setMetric('orders')}>Orders</button>
                  <button type="button" aria-pressed={metric === 'value'} onClick={() => setMetric('value')}>Order value</button>
                </div>
              }>
              {metric === 'orders'
                ? <AreaChart label="Orders placed" points={d.series.orders.map((x) => ({ day: x.day, value: x.count }))} />
                : <AreaChart label="Order value (excl. cancelled)" format={money} color="var(--c-accent)" points={d.series.orders.map((x) => ({ day: x.day, value: x.value }))} />}
            </Card>
            <Card className="status-card" title={<><span className="card-icon"><Icon d={I.cart} size={18} /></span>Order status</>}>
              <Donut label="Orders by status" slices={statusSlices} total={d.orders.total} centerLabel="Total Orders" />
            </Card>
          </>
        )}
        <Card className="approvals-card" title={<><span className="card-icon"><Icon d={CLOCK} size={18} /></span>Pending approvals</>} actions={<Link to="/vendors?verification_status=pending">Review all</Link>}>
          <ul className="approval-rows">
            <li><Link to="/vendors?verification_status=pending"><span className="card-icon sm"><Icon d={I.store} size={16} /></span><span>Vendor registrations</span><strong>{d ? pendingVendors : '—'}</strong><Icon d={CHEVRON} size={16} /></Link></li>
            <li><Link to="/service-bookings?status=pending"><span className="card-icon sm"><Icon d={I.calendar} size={16} /></span><span>Service bookings</span><strong>{d ? pendingBookings : '—'}</strong><Icon d={CHEVRON} size={16} /></Link></li>
          </ul>
          <Panel q={pending} empty={<EmptyState title="No pending applications" message="New vendor applications will appear here." />}>
            {(items) => (
              <ul className="list">
                {items.map((v) => (
                  <li key={v.id}><Link to={`/vendors/${v.id}`}><strong>{v.business_name}</strong><span className="muted">{v.city} · applied {dateOnly(v.created_at)}</span></Link><Button size="sm" variant="primary" onClick={() => nav(`/vendors/${v.id}`)}>Review</Button></li>
                ))}
              </ul>
            )}
          </Panel>
        </Card>
      </div>

      <div className="dash-activity">
        <Card className="quick-card" title={<><span className="card-icon"><Icon d={BOLT} size={18} /></span>Quick actions</>}>
          <div className="quick">
            <Link className="quick-tile tint-green wide" to="/vendors?verification_status=pending"><Icon d={I.store} size={22} />Approve vendor registrations</Link>
            <Link className="quick-tile tint-blue" to="/customers"><Icon d={I.people} size={22} />View customers</Link>
            <Link className="quick-tile tint-blue" to="/vendors"><Icon d={I.store} size={22} />Review vendors</Link>
            <Link className="quick-tile tint-purple" to="/orders"><Icon d={I.box} size={22} />View orders</Link>
            <Link className="quick-tile tint-orange" to="/service-bookings"><Icon d={I.calendar} size={22} />View service bookings</Link>
          </div>
        </Card>
        <Card title={<><span className="card-icon"><Icon d={I.people} size={18} /></span>Recent customers</>} actions={<Link to="/customers">View all →</Link>}>
          <Panel q={customers} empty={<EmptyState title="No customers yet" />}>
            {(items) => (
              <ul className="list">
                {items.map((c) => (
                  <li key={c.id}>
                    <Link to={`/customers/${c.id}`} className="person"><span className="avatar sm" aria-hidden="true">{initials(c.full_name, c.email)}</span><span className="person-text"><strong>{c.full_name || c.email || 'Unnamed customer'}</strong><span className="muted">{dateOnly(c.created_at)}</span></span></Link>
                    <StatusBadge status={c.status} />
                  </li>
                ))}
              </ul>
            )}
          </Panel>
        </Card>
        <Card title={<><span className="card-icon"><Icon d={I.store} size={18} /></span>Recent vendors</>} actions={<Link to="/vendors">View all →</Link>}>
          <Panel q={vendors} empty={<EmptyState title="No vendors yet" message="New vendors will appear here." />}>
            {(items) => (
              <ul className="list">
                {items.map((v) => (
                  <li key={v.id}>
                    <Link to={`/vendors/${v.id}`} className="person"><span className="avatar sm" aria-hidden="true">{initials(v.business_name, null)}</span><span className="person-text"><strong>{v.business_name}</strong><span className="muted">{dateOnly(v.created_at)}</span></span></Link>
                    <StatusBadge status={v.verification_status} />
                  </li>
                ))}
              </ul>
            )}
          </Panel>
        </Card>
        <Card className="health-card" title={<><span className="card-icon"><Icon d={PULSE} size={18} /></span>Platform health</>}>
          <ul className="health">
            {health.map((h) => (
              <li key={h.label}>
                <span className={`health-mark ${h.ok === null ? 'wait' : h.ok ? 'ok' : 'bad'}`} aria-hidden="true">{h.ok ? <Icon d={CHECK} size={14} /> : h.ok === false ? '!' : '…'}</span>
                <span>{h.label}</span>
                <span className={`pill ${h.ok === null ? 'pill-wait' : h.ok ? 'pill-ok' : 'pill-bad'}`}>{h.text}</span>
              </li>
            ))}
          </ul>
          <p className="muted small">Checked from this page’s live requests to the backend.</p>
        </Card>
      </div>

      {d && (
        <>
          <h2 className="dash-section">Operational snapshot</h2>
          <div className="grid metrics">
            <MetricCard label="Pending vendor approvals" value={d.vendors.by_verification.pending ?? 0} tone={(d.vendors.by_verification.pending ?? 0) > 0 ? 'warn' : 'default'} to="/vendors?verification_status=pending" hint="Awaiting your review" />
            <MetricCard label="Approved vendors" value={d.vendors.by_verification.approved ?? 0} tone="good" to="/vendors?verification_status=approved" />
            <MetricCard label="Suspended vendors" value={d.vendors.by_verification.suspended ?? 0} tone={(d.vendors.by_verification.suspended ?? 0) > 0 ? 'bad' : 'default'} to="/vendors?verification_status=suspended" />
            <MetricCard label="Pending orders" value={d.orders.by_status.pending ?? 0} tone="warn" />
            <MetricCard label="Completed orders" value={d.orders.by_status.completed ?? 0} tone="good" hint={`${money(d.orders.value_completed)} order value`} />
            <MetricCard label="Cancelled orders" value={d.orders.by_status.cancelled ?? 0} />
          </div>

          <div className="grid two">
            <Card title="Payment collection" actions={payments.loading ? <span className="muted">Loading…</span> : null}>
              {payments.error && !payments.data ? <ErrorState compact error={payments.error} onRetry={payments.reload} /> : payments.data ? (
                <dl className="kv">
                  <div className="kv-row"><dt>Collected (online & COD recorded)</dt><dd>{money(payments.data.collected)}</dd></div>
                  <div className="kv-row"><dt>Refunded (processed)</dt><dd>{money(payments.data.refunded)}</dd></div>
                  <div className="kv-row"><dt>Net collected</dt><dd><strong>{money(payments.data.net_collected)}</strong></dd></div>
                  <div className="kv-row"><dt>Commission earned</dt><dd>{money(payments.data.commission_earned)}</dd></div>
                  <div className="kv-row"><dt>COD still to collect</dt><dd>{money(payments.data.cod_outstanding)}</dd></div>
                  <p className="muted small">For {dateOnly(payments.data.period_from)} – {dateOnly(payments.data.period_to)}. Payment records come from the payments ledger; nothing is estimated.</p>
                </dl>
              ) : <PageLoading />}
            </Card>
            <Card title="Order value">
              <dl className="kv">
                <div className="kv-row"><dt>Completed orders</dt><dd><strong>{money(d.orders.value_completed)}</strong></dd></div>
                <div className="kv-row"><dt>Confirmed, in progress</dt><dd>{money(d.orders.value_confirmed)}</dd></div>
              </dl>
              <p className="muted small">Total order amount (items + delivery − discounts) in each state; cancelled orders are excluded. Revenue to the platform is the commission above.</p>
            </Card>
          </div>
        </>
      )}

      <div className="grid two">
        <Card title="Recent orders" actions={<Link to="/orders">View all →</Link>}>
          <Panel q={orders} empty={<EmptyState title="No orders yet" />}>
            {(items) => <ul className="list">{items.map((o) => <li key={o.id}><span><strong>{o.order_number}</strong><span className="muted"> {o.customer?.full_name ?? 'Customer'} · {dateTime(o.created_at)}</span></span><span className="row-end">{money(o.total_amount)} <StatusBadge status={o.status} /></span></li>)}</ul>}
          </Panel>
        </Card>
        <Card title="Recent service bookings" actions={<Link to="/service-bookings">View all →</Link>}>
          <Panel q={bookings} empty={<EmptyState title="No bookings yet" />}>
            {(items) => <ul className="list">{items.map((b) => <li key={b.id}><span><strong>{b.booking_number}</strong><span className="muted"> {b.service_name} · {b.vendor_name ?? ''}</span></span><span className="row-end">{money(b.current_price)} <StatusBadge status={b.status} /></span></li>)}</ul>}
          </Panel>
        </Card>
      </div>

      {d && (
        <>
          <h2 className="dash-section">Growth and activity</h2>
          <div className="grid three">
            <Card title="New customers per day"><DailyBars label="New customers" color="var(--c-blue)" points={d.series.customers.map((x) => ({ day: x.day, value: x.count }))} /></Card>
            <Card title="New vendor applications per day"><DailyBars label="New vendors" color="var(--c-purple)" points={d.series.vendors.map((x) => ({ day: x.day, value: x.count }))} /></Card>
            <Card title="Service bookings per day"><DailyBars label="Bookings created" color="var(--c-green)" points={d.series.bookings.map((x) => ({ day: x.day, value: x.count }))} /></Card>
          </div>
        </>
      )}
    </div>
  )
}
