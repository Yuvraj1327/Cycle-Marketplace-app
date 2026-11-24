import { Link, useParams } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { AccountActions } from '../../components/common/AccountActions'
import { Card, EmptyState, ErrorState, KeyValue, PageLoading, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { ApiError } from '../../services/api/client'
import type { AuditEntry } from '../../types/api'
import { dateTime, humanize, money } from '../../utils/format'

export function ActivityLog({ entries }: { entries: AuditEntry[] }) {
  if (entries.length === 0) return <p className="muted">No administrative actions recorded.</p>
  return (
    <ol className="timeline">
      {entries.map((a, i) => (
        <li key={`${a.at}-${i}`}>
          <strong>{humanize(a.action.replace(/^(customer|vendor)_/, ''))}</strong>
          <span className="muted"> · {dateTime(a.at)}{a.actor_id ? ` · by admin ${a.actor_id.slice(0, 8)}` : ''}</span>
          {typeof a.details.reason === 'string' && a.details.reason && <p>Reason: {a.details.reason}</p>}
          {typeof a.details.note === 'string' && a.details.note && <p>Note: {a.details.note}</p>}
        </li>
      ))}
    </ol>
  )
}

export function CustomerDetailPage() {
  const { id = '' } = useParams()
  const s = useServices()
  const toast = useToast()
  const customer = useAsync(() => s.customers.get(id), [id])
  const orders = useAsync(() => s.customers.orders(id), [id])
  const bookings = useAsync(() => s.customers.bookings(id), [id])

  if (customer.loading && !customer.data) return <PageLoading />
  if (customer.error && !customer.data) {
    const missing = customer.error instanceof ApiError && customer.error.kind === 'not_found'
    return missing ? <EmptyState title="Customer not found" message="This customer does not exist." action={<Link to="/customers">Back to customers</Link>} /> : <ErrorState error={customer.error} onRetry={customer.reload} />
  }
  const c = customer.data!
  const name = c.full_name || c.email || 'Unnamed customer'

  return (
    <>
      <PageHeader
        title={<>{name} <StatusBadge status={c.status} /></>}
        crumbs={[{ label: 'Overview', to: '/' }, { label: 'Customers', to: '/customers' }, { label: name }]}
        actions={<AccountActions current={c.status} who={name} apply={async (st, reason) => {
          await s.customers.setStatus(c.id, st, reason)
          toast.success(`Customer ${st === 'active' ? 'activated' : st === 'inactive' ? 'deactivated' : 'restricted'}`)
          customer.reload()
        }} />}
      />
      <div className="grid two">
        <Card title="Profile">
          <KeyValue rows={[['Customer ID', <code key="i">{c.id}</code>], ['Name', c.full_name], ['E-mail', c.email], ['Phone', c.phone], ['Registered', dateTime(c.created_at)], ['Status', <StatusBadge key="s" status={c.status} />], ['Orders', c.order_count], ['Service bookings', c.booking_count]]} />
          <p className="muted small">Passwords are managed by the sign-in provider and are never visible to administrators.</p>
        </Card>
        <Card title="Saved addresses">
          {c.addresses.length === 0 ? <p className="muted">No saved addresses.</p> : (
            <ul className="address-list">
              {c.addresses.map((a) => (
                <li key={a.id}>
                  <strong>{a.label || a.recipient_name || 'Address'}</strong>{a.is_default && <span className="badge badge-blue">Default</span>}
                  <div>{[a.recipient_name, a.address_line1, a.address_line2, a.landmark, a.city, [a.state, a.postal_code].filter(Boolean).join(' ')].filter(Boolean).join(', ')}</div>
                  {a.phone && <div className="muted">{a.phone}</div>}
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
      <Card title="Order history" actions={orders.data ? <span className="muted">{orders.data.total} total{orders.data.total > orders.data.items.length ? ` · showing latest ${orders.data.items.length}` : ''}</span> : null}>
        <DataTable caption="Orders" rows={orders.data?.items ?? null} rowKey={(o) => o.id} loading={orders.loading} error={orders.error} onRetry={orders.reload} emptyTitle="No orders" emptyMessage="This customer has not placed an order."
          columns={[
            { key: 'n', header: 'Order', render: (o) => <strong>{o.order_number}</strong> },
            { key: 'd', header: 'Placed', render: (o) => dateTime(o.created_at) },
            { key: 'st', header: 'Status', render: (o) => <StatusBadge status={o.status} /> },
            { key: 'p', header: 'Payment', render: (o) => `${o.payment_method === 'cod' ? 'COD' : 'Online'} · ${humanize(o.payment_status)}` },
            { key: 't', header: 'Total', align: 'right', render: (o) => money(o.total_amount) },
          ]} />
      </Card>
      <Card title="Service booking history" actions={bookings.data ? <span className="muted">{bookings.data.total} total</span> : null}>
        <DataTable caption="Service bookings" rows={bookings.data?.items ?? null} rowKey={(b) => b.id} loading={bookings.loading} error={bookings.error} onRetry={bookings.reload} emptyTitle="No bookings" emptyMessage="This customer has not booked a service."
          columns={[
            { key: 'n', header: 'Booking', render: (b) => <strong>{b.booking_number}</strong> },
            { key: 'sv', header: 'Service', render: (b) => `${b.service_name}${b.vendor_name ? ` · ${b.vendor_name}` : ''}` },
            { key: 'd', header: 'Preferred date', render: (b) => b.preferred.date ?? '—' },
            { key: 'st', header: 'Status', render: (b) => <StatusBadge status={b.status} /> },
            { key: 'p', header: 'Price', align: 'right', render: (b) => money(b.current_price) },
          ]} />
      </Card>
      <Card title="Administrative activity"><ActivityLog entries={c.activity} /></Card>
    </>
  )
}
