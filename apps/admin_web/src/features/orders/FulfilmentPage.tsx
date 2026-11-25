import { Link, useNavigate } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { Button, Card, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { DateRange } from '../../components/common/filters'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import type { FulfilmentItem } from '../../types/api'
import { dateTime, humanize, money } from '../../utils/format'
import { OrderTabs } from './OrdersPage'

const LIMIT = 20
const STATUSES = [{ value: '', label: 'All' }, ...['pending', 'accepted', 'preparing', 'ready_for_dispatch', 'out_for_delivery', 'delivered', 'rejected', 'cancelled'].map((v) => ({ value: v, label: humanize(v) }))]

export function FulfilmentPage() {
  const s = useServices()
  const nav = useNavigate()
  const { values, page, set, setPage } = useListQuery(['q', 'status', 'vendor_id', 'date_from', 'date_to'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const vendors = useAsync(() => s.vendors.list({ verification_status: 'approved', limit: 100 }), [])
  const list = useAsync(() => s.fulfilment.list({ q: values.q, status: values.status, vendor_id: values.vendor_id, date_from: values.date_from, date_to: values.date_to, page, limit: LIMIT }),
    [values.q, values.status, values.vendor_id, values.date_from, values.date_to, page])

  const columns: Column<FulfilmentItem>[] = [
    { key: 'vo', header: 'Fulfilment', render: (f) => <strong>{f.vendor_order_number}</strong> },
    { key: 'o', header: 'Order', render: (f) => <Link to={`/orders/${f.order_id}`} onClick={(e) => e.stopPropagation()}>{f.order_number ?? '—'}</Link> },
    { key: 'v', header: 'Vendor', render: (f) => f.vendor_name ?? '—' },
    { key: 'c', header: 'Customer', render: (f) => f.customer_name ?? '—' },
    { key: 'd', header: 'Deliver to', render: (f) => [f.delivery_city, f.delivery_postal_code].filter(Boolean).join(' ') || '—' },
    { key: 'i', header: 'Items', align: 'right', render: (f) => f.item_count },
    { key: 'a', header: 'Amount', align: 'right', render: (f) => money(f.total_amount) },
    { key: 'p', header: 'Payment', render: (f) => <>{f.payment_method === 'cod' ? 'Cash on delivery' : 'Online'} <StatusBadge status={f.payment_status} /></> },
    { key: 's', header: 'Fulfilment', render: (f) => <StatusBadge status={f.status} /> },
    { key: 'ac', header: 'Accepted', render: (f) => dateTime(f.accepted_at) },
    { key: 'de', header: 'Delivered', render: (f) => dateTime(f.delivered_at) },
  ]

  return (
    <>
      <PageHeader title="Delivery & fulfilment" subtitle="Where every vendor order stands. Monitoring only: vendors update their own fulfilment steps." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Orders', to: '/orders' }, { label: 'Fulfilment' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <OrderTabs active="fulfilment" />
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search order, customer or vendor" />
          <SelectFilter label="Fulfilment status" value={values.status} onChange={(v) => set({ status: v })} options={STATUSES} />
          <SelectFilter label="Vendor" value={values.vendor_id} onChange={(v) => set({ vendor_id: v })} options={[{ value: '', label: 'All vendors' }, ...(vendors.data?.items ?? []).map((v) => ({ value: v.id, label: v.business_name }))]} />
          <DateRange from={values.date_from} to={values.date_to} onChange={(r) => set({ date_from: r.from, date_to: r.to })} />
        </div>
        <p className="muted small">Orders appear here once they are released to the vendor (cash-on-delivery orders at checkout, online orders after payment is verified). There is no courier or GPS tracking: the status is what the vendor recorded.</p>
        <DataTable caption="Vendor orders" columns={columns} rows={list.data?.items ?? null} rowKey={(f) => f.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={(f) => nav(`/orders/${f.order_id}`)} emptyTitle="No fulfilment records" emptyMessage="Try changing the filters." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
