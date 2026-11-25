import { Link, useNavigate } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { Button, Card, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { DateRange, Tabs } from '../../components/common/filters'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import type { AdminOrder } from '../../types/api'
import { dateTime, money } from '../../utils/format'
import { METHODS, ORDER_STATUSES, PAYMENT_STATUSES } from '../../utils/options'

const LIMIT = 20
const SORTS = [{ value: 'newest', label: 'Newest first' }, { value: 'oldest', label: 'Oldest first' }, { value: 'amount_high', label: 'Amount: high to low' }, { value: 'amount_low', label: 'Amount: low to high' }]

export function OrderTabs({ active }: { active: 'orders' | 'fulfilment' }) {
  const nav = useNavigate()
  return <Tabs label="Order views" value={active} onChange={(v) => nav(v === 'orders' ? '/orders' : '/orders/fulfilment')} tabs={[{ value: 'orders', label: 'Customer orders' }, { value: 'fulfilment', label: 'Delivery & fulfilment' }]} />
}

function productSummary(o: AdminOrder): string {
  const lines = o.vendor_orders.flatMap((v) => v.items).map((i) => `${i.product_name}${i.quantity > 1 ? ` ×${i.quantity}` : ''}`)
  return lines.length <= 2 ? lines.join(', ') : `${lines.slice(0, 2).join(', ')} +${lines.length - 2} more`
}

export function OrdersPage() {
  const s = useServices()
  const nav = useNavigate()
  const { values, page, set, setPage } = useListQuery(['q', 'status', 'payment_status', 'payment_method', 'date_from', 'date_to', 'sort'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const sort = values.sort || 'newest'
  const list = useAsync(() => s.orders.list({ q: values.q, status: values.status, payment_status: values.payment_status, payment_method: values.payment_method, date_from: values.date_from, date_to: values.date_to, sort, page, limit: LIMIT }),
    [values.q, values.status, values.payment_status, values.payment_method, values.date_from, values.date_to, sort, page])

  const columns: Column<AdminOrder>[] = [
    { key: 'no', header: 'Order', render: (o) => <Link to={`/orders/${o.id}`} onClick={(e) => e.stopPropagation()}><strong>{o.order_number}</strong></Link> },
    { key: 'cust', header: 'Customer', render: (o) => <>{o.customer?.full_name ?? '—'}<div className="muted small">{o.customer?.phone ?? o.customer?.email ?? ''}</div></> },
    { key: 'date', header: 'Placed', render: (o) => dateTime(o.created_at) },
    { key: 'vendor', header: 'Vendor', render: (o) => [...new Set(o.vendor_orders.map((v) => v.vendor_name ?? '—'))].join(', ') },
    { key: 'items', header: 'Products', render: (o) => <span className="small">{productSummary(o)}</span> },
    { key: 'amt', header: 'Amount', align: 'right', render: (o) => money(o.total_amount) },
    { key: 'pm', header: 'Method', render: (o) => (o.payment_method === 'cod' ? 'Cash on delivery' : 'Online') },
    { key: 'ps', header: 'Payment', render: (o) => <StatusBadge status={o.payment_status} /> },
    { key: 'st', header: 'Order', render: (o) => <StatusBadge status={o.status} /> },
    { key: 'act', header: '', align: 'right', render: (o) => <Button size="sm" onClick={() => nav(`/orders/${o.id}`)}>View</Button> },
  ]

  return (
    <>
      <PageHeader title="Orders" subtitle="Every customer order across all vendors." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Orders' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <OrderTabs active="orders" />
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search order number, customer or vendor" />
          <SelectFilter label="Order status" value={values.status} onChange={(v) => set({ status: v })} options={ORDER_STATUSES} />
          <SelectFilter label="Payment status" value={values.payment_status} onChange={(v) => set({ payment_status: v })} options={PAYMENT_STATUSES} />
          <SelectFilter label="Payment method" value={values.payment_method} onChange={(v) => set({ payment_method: v })} options={METHODS} />
          <DateRange from={values.date_from} to={values.date_to} onChange={(r) => set({ date_from: r.from, date_to: r.to })} />
          <SelectFilter label="Sort" value={sort} onChange={(v) => set({ sort: v === 'newest' ? '' : v })} options={SORTS} />
        </div>
        <p className="muted small">An order is Pending until paid (online) or confirmed (cash on delivery) and becomes Completed once every vendor has delivered. Per-vendor steps (accepted, preparing, ready for dispatch, out for delivery, delivered) are on the Delivery &amp; fulfilment tab.</p>
        <DataTable caption="Orders" columns={columns} rows={list.data?.items ?? null} rowKey={(o) => o.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={(o) => nav(`/orders/${o.id}`)} emptyTitle="No orders found" emptyMessage="Try changing the search or filters." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
