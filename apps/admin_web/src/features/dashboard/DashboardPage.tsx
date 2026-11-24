import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { DailyBars, DistributionBars } from '../../components/charts/charts'
import { Button, Card, EmptyState, ErrorState, MetricCard, PageLoading, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { useAsync } from '../../hooks/useAsync'
import { compactNumber, dateOnly, dateTime, isoDay, money } from '../../utils/format'

const RANGES = [{ days: 7, label: 'Last 7 days' }, { days: 30, label: 'Last 30 days' }, { days: 90, label: 'Last 90 days' }]

function period(days: number): { from: string; to: string } {
  const to = new Date()
  const from = new Date()
  from.setDate(to.getDate() - (days - 1))
  return { from: isoDay(from), to: isoDay(to) }
}

export function DashboardPage() {
  const s = useServices()
  const nav = useNavigate()
  const [days, setDays] = useState(30)
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

  return (
    <>
      <PageHeader
        title="Overview"
        subtitle="Live figures from the marketplace database."
        actions={
          <>
            <select aria-label="Period" className="select" value={days} onChange={(e) => setDays(Number(e.target.value))}>
              {RANGES.map((r) => <option key={r.days} value={r.days}>{r.label}</option>)}
            </select>
            <Button onClick={refresh}>Refresh</Button>
          </>
        }
      />

      {summary.loading && !d && <PageLoading label="Loading dashboard…" />}
      {summary.error && !d && <ErrorState error={summary.error} onRetry={summary.reload} />}
      {d && (
        <>
          <div className="grid metrics">
            <MetricCard label="Customers" value={compactNumber(d.customers.total)} hint={`${d.customers.new_in_period} new in period`} to="/customers" />
            <MetricCard label="Vendors" value={compactNumber(d.vendors.total)} hint={`${d.vendors.new_in_period} new in period`} to="/vendors" />
            <MetricCard label="Pending vendor approvals" value={d.vendors.by_verification.pending ?? 0} tone={(d.vendors.by_verification.pending ?? 0) > 0 ? 'warn' : 'default'} to="/vendors?verification_status=pending" hint="Awaiting your review" />
            <MetricCard label="Approved vendors" value={d.vendors.by_verification.approved ?? 0} tone="good" to="/vendors?verification_status=approved" />
            <MetricCard label="Suspended vendors" value={d.vendors.by_verification.suspended ?? 0} tone={(d.vendors.by_verification.suspended ?? 0) > 0 ? 'bad' : 'default'} to="/vendors?verification_status=suspended" />
            <MetricCard label="Service bookings" value={compactNumber(d.bookings.total)} hint={`${d.bookings.by_status.pending ?? 0} pending`} />
            <MetricCard label="Total orders" value={compactNumber(d.orders.total)} />
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

          <div className="grid two">
            <Card title="Orders per day"><DailyBars label="Orders placed" points={d.series.orders.map((x) => ({ day: x.day, value: x.count }))} /></Card>
            <Card title="Order value per day"><DailyBars label="Order value (excl. cancelled)" format={money} color="var(--c-accent)" points={d.series.orders.map((x) => ({ day: x.day, value: x.value }))} /></Card>
            <Card title="New customers per day"><DailyBars label="New customers" color="var(--c-blue)" points={d.series.customers.map((x) => ({ day: x.day, value: x.count }))} /></Card>
            <Card title="New vendor applications per day"><DailyBars label="New vendors" color="var(--c-purple)" points={d.series.vendors.map((x) => ({ day: x.day, value: x.count }))} /></Card>
            <Card title="Service bookings per day"><DailyBars label="Bookings created" color="var(--c-green)" points={d.series.bookings.map((x) => ({ day: x.day, value: x.count }))} /></Card>
            <Card title="Orders by status">
              <DistributionBars rows={['pending', 'confirmed', 'completed', 'cancelled'].map((k) => ({ label: k[0].toUpperCase() + k.slice(1), value: d.orders.by_status[k] ?? 0, tone: ({ pending: 'amber', confirmed: 'blue', completed: 'green', cancelled: 'red' } as Record<string, string>)[k] }))} />
            </Card>
          </div>
        </>
      )}

      <div className="grid two">
        <Card title="Pending vendor approvals" actions={<Link to="/vendors?verification_status=pending">Review all</Link>}>
          {pending.error ? <ErrorState compact error={pending.error} onRetry={pending.reload} /> : pending.loading && !pending.data ? <PageLoading /> : pending.data?.items.length === 0 ? <EmptyState title="No pending applications" message="New vendor applications will appear here." /> : (
            <ul className="list">
              {pending.data?.items.map((v) => (
                <li key={v.id}><Link to={`/vendors/${v.id}`}><strong>{v.business_name}</strong><span className="muted">{v.city} · applied {dateOnly(v.created_at)}</span></Link><Button size="sm" variant="primary" onClick={() => nav(`/vendors/${v.id}`)}>Review</Button></li>
              ))}
            </ul>
          )}
        </Card>
        <Card title="Quick actions">
          <div className="quick">
            <Link className="btn btn-secondary btn-md" to="/customers">View customers</Link>
            <Link className="btn btn-secondary btn-md" to="/vendors">Review vendors</Link>
            <Link className="btn btn-primary btn-md" to="/vendors?verification_status=pending">Approve vendor registrations</Link>
            <Link className="btn btn-secondary btn-md" to="/orders">View orders</Link>
            <Link className="btn btn-secondary btn-md" to="/services">View service bookings</Link>
          </div>
          <p className="muted small">Order and booking management arrive in the next development phase; the lists below are read-only.</p>
        </Card>
        <Card title="Recently registered customers" actions={<Link to="/customers">All customers</Link>}>
          {customers.error ? <ErrorState compact error={customers.error} onRetry={customers.reload} /> : customers.loading && !customers.data ? <PageLoading /> : customers.data?.items.length === 0 ? <EmptyState title="No customers yet" /> : (
            <ul className="list">{customers.data?.items.map((c) => <li key={c.id}><Link to={`/customers/${c.id}`}><strong>{c.full_name || c.email || 'Unnamed customer'}</strong><span className="muted">{dateOnly(c.created_at)}</span></Link><StatusBadge status={c.status} /></li>)}</ul>
          )}
        </Card>
        <Card title="Recently registered vendors" actions={<Link to="/vendors">All vendors</Link>}>
          {vendors.error ? <ErrorState compact error={vendors.error} onRetry={vendors.reload} /> : vendors.loading && !vendors.data ? <PageLoading /> : vendors.data?.items.length === 0 ? <EmptyState title="No vendors yet" /> : (
            <ul className="list">{vendors.data?.items.map((v) => <li key={v.id}><Link to={`/vendors/${v.id}`}><strong>{v.business_name}</strong><span className="muted">{dateOnly(v.created_at)}</span></Link><StatusBadge status={v.verification_status} /></li>)}</ul>
          )}
        </Card>
        <Card title="Recent orders">
          {orders.error ? <ErrorState compact error={orders.error} onRetry={orders.reload} /> : orders.loading && !orders.data ? <PageLoading /> : orders.data?.items.length === 0 ? <EmptyState title="No orders yet" /> : (
            <ul className="list">{orders.data?.items.map((o) => <li key={o.id}><span><strong>{o.order_number}</strong><span className="muted"> {o.customer?.full_name ?? 'Customer'} · {dateTime(o.created_at)}</span></span><span className="row-end">{money(o.total_amount)} <StatusBadge status={o.status} /></span></li>)}</ul>
          )}
        </Card>
        <Card title="Recent service bookings">
          {bookings.error ? <ErrorState compact error={bookings.error} onRetry={bookings.reload} /> : bookings.loading && !bookings.data ? <PageLoading /> : bookings.data?.items.length === 0 ? <EmptyState title="No bookings yet" /> : (
            <ul className="list">{bookings.data?.items.map((b) => <li key={b.id}><span><strong>{b.booking_number}</strong><span className="muted"> {b.service_name} · {b.vendor_name ?? ''}</span></span><span className="row-end">{money(b.current_price)} <StatusBadge status={b.status} /></span></li>)}</ul>
          )}
        </Card>
      </div>
    </>
  )
}
