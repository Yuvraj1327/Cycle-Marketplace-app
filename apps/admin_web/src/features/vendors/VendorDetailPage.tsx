import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { Card, EmptyState, ErrorState, KeyValue, PageLoading, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { ApiError } from '../../services/api/client'
import { dateTime, humanize, money } from '../../utils/format'
import { ActivityLog } from '../customers/CustomerDetailPage'
import { BUSINESS_LABELS } from '../../utils/labels'
import { VendorDecisionButtons } from './VendorDecisions'

const DAYS: [string, string][] = [['mon', 'Monday'], ['tue', 'Tuesday'], ['wed', 'Wednesday'], ['thu', 'Thursday'], ['fri', 'Friday'], ['sat', 'Saturday'], ['sun', 'Sunday']]
type Tab = 'products' | 'orders' | 'bookings'

function VendorTab({ id, tab }: { id: string; tab: Tab }) {
  const s = useServices()
  const products = useAsync(() => (tab === 'products' ? s.vendors.products(id) : Promise.resolve(null)), [id, tab])
  const orders = useAsync(() => (tab === 'orders' ? s.vendors.orders(id) : Promise.resolve(null)), [id, tab])
  const bookings = useAsync(() => (tab === 'bookings' ? s.vendors.bookings(id) : Promise.resolve(null)), [id, tab])
  if (tab === 'products') {
    return <DataTable caption="Products" rows={products.data?.items ?? null} rowKey={(p) => p.id} loading={products.loading} error={products.error} onRetry={products.reload} emptyTitle="No products" emptyMessage="This vendor has not listed any product."
      columns={[
        { key: 'n', header: 'Product', render: (p) => <><strong>{p.name}</strong><div className="muted small">{[p.brand, p.model].filter(Boolean).join(' · ')}</div></> },
        { key: 'ty', header: 'Type', render: (p) => humanize(p.product_type) },
        { key: 'pr', header: 'Price', align: 'right', render: (p) => money(p.price) },
        { key: 'st', header: 'Stock', align: 'right', render: (p) => p.stock_quantity },
        { key: 'ap', header: 'Approval', render: (p) => <StatusBadge status={p.is_active ? p.approval_status : 'inactive'} /> },
      ]} />
  }
  if (tab === 'orders') {
    return <DataTable caption="Orders" rows={orders.data?.items ?? null} rowKey={(o) => o.id} loading={orders.loading} error={orders.error} onRetry={orders.reload} emptyTitle="No orders" emptyMessage="This vendor has not received an order."
      columns={[
        { key: 'n', header: 'Order', render: (o) => <strong>{o.order_number}</strong> },
        { key: 'c', header: 'Customer', render: (o) => o.customer?.full_name ?? '—' },
        { key: 'd', header: 'Placed', render: (o) => dateTime(o.created_at) },
        { key: 'st', header: 'Vendor order', render: (o) => <StatusBadge status={o.vendor_orders.find((v) => v.vendor_id === id)?.status ?? o.status} /> },
        { key: 't', header: 'Order total', align: 'right', render: (o) => money(o.total_amount) },
      ]} />
  }
  return <DataTable caption="Service bookings" rows={bookings.data?.items ?? null} rowKey={(b) => b.id} loading={bookings.loading} error={bookings.error} onRetry={bookings.reload} emptyTitle="No bookings" emptyMessage="This vendor has not received a service booking."
    columns={[
      { key: 'n', header: 'Booking', render: (b) => <strong>{b.booking_number}</strong> },
      { key: 'sv', header: 'Service', render: (b) => b.service_name },
      { key: 'c', header: 'Customer', render: (b) => b.customer?.full_name ?? '—' },
      { key: 'st', header: 'Status', render: (b) => <StatusBadge status={b.status} /> },
      { key: 'p', header: 'Price', align: 'right', render: (b) => money(b.current_price) },
    ]} />
}

export function VendorDetailPage() {
  const { id = '' } = useParams()
  const s = useServices()
  const vendor = useAsync(() => s.vendors.get(id), [id])
  const [tab, setTab] = useState<Tab>('products')

  if (vendor.loading && !vendor.data) return <PageLoading />
  if (vendor.error && !vendor.data) {
    const missing = vendor.error instanceof ApiError && vendor.error.kind === 'not_found'
    return missing ? <EmptyState title="Vendor not found" message="This vendor does not exist." action={<Link to="/vendors">Back to vendors</Link>} /> : <ErrorState error={vendor.error} onRetry={vendor.reload} />
  }
  const v = vendor.data!
  const address = [v.address_line1, v.address_line2, v.city, `${v.state} ${v.postal_code}`].filter(Boolean).join(', ')

  return (
    <>
      <PageHeader
        title={<>{v.business_name} <StatusBadge status={v.verification_status} /></>}
        subtitle={v.verification_status === 'pending' ? 'Application waiting for review' : undefined}
        crumbs={[{ label: 'Overview', to: '/' }, { label: 'Vendors', to: '/vendors' }, { label: v.business_name }]}
      />
      <Card title="Decision" className="decision">
        <div className="decision-row">
          <div>
            <p><strong>Verification:</strong> <StatusBadge status={v.verification_status} /> &nbsp; <strong>Account:</strong> <StatusBadge status={v.account_status} /></p>
            {v.verification_status === 'rejected' && v.rejection_reason && <p className="muted">Rejected: {v.rejection_reason}</p>}
            {v.verification_status === 'suspended' && v.rejection_reason && <p className="muted">Suspended: {v.rejection_reason}</p>}
            {v.reviewed_at && <p className="muted small">Last decision {dateTime(v.reviewed_at)}{v.reviewed_by ? ` by admin ${v.reviewed_by.slice(0, 8)}` : ''}{v.review_notes ? ` · “${v.review_notes}”` : ''}</p>}
          </div>
          <div className="row-actions"><VendorDecisionButtons vendor={v} onChanged={vendor.reload} /></div>
        </div>
      </Card>

      <div className="grid two">
        <Card title="Business">
          <KeyValue rows={[
            ['Vendor ID', <code key="i">{v.id}</code>], ['Business name', v.business_name], ['Type', v.business_types.map((t) => BUSINESS_LABELS[t] ?? t).join(', ')], ['About', v.description],
            ['Registered', dateTime(v.created_at)], ['Products / orders / bookings', `${v.product_count ?? '—'} / ${v.order_count ?? '—'} / ${v.booking_count ?? '—'}`],
          ]} />
        </Card>
        <Card title="Contact & owner">
          <KeyValue rows={[['Owner', v.owner_name], ['Owner e-mail', v.owner_email], ['Owner phone', v.owner_phone], ['Business phone', v.contact_phone], ['Business e-mail', v.contact_email], ['Address', address]]} />
        </Card>
        <Card title="Operating hours">
          <dl className="kv">
            {DAYS.map(([k, label]) => {
              const h = v.operating_hours[k]
              return <div className="kv-row" key={k}><dt>{label}</dt><dd>{!h || h.closed ? <span className="muted">Closed</span> : `${h.open} – ${h.close}`}</dd></div>
            })}
          </dl>
          {Object.keys(v.operating_hours).length === 0 && <p className="muted small">No opening hours submitted: customers cannot book services until they are set.</p>}
        </Card>
        <Card title="Pickup & service area">
          <KeyValue rows={[['Doorstep pickup', v.pickup_available ? 'Offered' : 'Not offered'], ['Service-area postal codes', v.service_area_postal_codes.length ? v.service_area_postal_codes.join(', ') : 'Any address'], ['Service radius', v.service_radius_km !== null ? `${v.service_radius_km} km` : '—'], ['Account status', <StatusBadge key="a" status={v.account_status} />]]} />
        </Card>
      </div>

      <Card title={`Shop images (${v.shop_image_urls.length})`}>
        {v.shop_image_urls.length === 0 ? <p className="muted">No shop images submitted.</p> : (
          <div className="gallery">{v.shop_image_urls.map((u, i) => <a key={u} href={u} target="_blank" rel="noreferrer noopener"><img src={u} alt={`${v.business_name} shop photo ${i + 1}`} loading="lazy" /></a>)}</div>
        )}
      </Card>

      <Card title="Business activity">
        <div className="tabs" role="tablist" aria-label="Vendor activity">
          {(['products', 'orders', 'bookings'] as Tab[]).map((t) => <button key={t} type="button" role="tab" aria-selected={tab === t} className={tab === t ? 'tab active' : 'tab'} onClick={() => setTab(t)}>{humanize(t)}</button>)}
        </div>
        <VendorTab id={v.id} tab={tab} />
      </Card>
      <Card title="Administrative activity"><ActivityLog entries={v.activity} /></Card>
    </>
  )
}
