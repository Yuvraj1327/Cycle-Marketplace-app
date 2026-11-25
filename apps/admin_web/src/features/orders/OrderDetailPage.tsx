import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, EmptyState, ErrorState, KeyValue, PageLoading, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { ApiError } from '../../services/api/client'
import type { AdminOrder, VendorOrder } from '../../types/api'
import { dateTime, humanize, money } from '../../utils/format'
import { Timeline } from '../common/Timeline'
import { TicketsPanel } from '../support/TicketsPanel'

const ACTIVE_VENDOR = ['pending', 'accepted', 'preparing', 'ready_for_dispatch', 'out_for_delivery']

function address(a: AdminOrder['delivery_address']): string {
  return [a.recipient_name, a.address_line1, a.address_line2, a.landmark, [a.city, a.state, a.postal_code].filter(Boolean).join(' '), a.phone].filter(Boolean).join(', ') || '—'
}

export function OrderDetailPage() {
  const { id = '' } = useParams()
  const s = useServices()
  const toast = useToast()
  const order = useAsync(() => s.orders.get(id), [id])
  const timeline = useAsync(() => s.orders.timeline(id), [id])
  const tickets = useAsync(() => s.orders.tickets(id), [id])
  const [cancel, setCancel] = useState(false)
  const [cancelVo, setCancelVo] = useState<VendorOrder | null>(null)

  if (order.loading && !order.data) return <PageLoading />
  if (order.error && !order.data) {
    const missing = order.error instanceof ApiError && order.error.kind === 'not_found'
    return missing ? <Card><EmptyState title="Order not found" action={<Link to="/orders">Back to orders</Link>} /></Card> : <ErrorState error={order.error} onRetry={order.reload} />
  }
  const o = order.data as AdminOrder
  const refresh = () => { order.reload(); timeline.reload() }
  const cancellable = o.status === 'pending' || o.status === 'confirmed'

  return (
    <>
      <PageHeader title={`Order ${o.order_number}`} subtitle={`Placed ${dateTime(o.created_at)}`} crumbs={[{ label: 'Overview', to: '/' }, { label: 'Orders', to: '/orders' }, { label: o.order_number }]}
        actions={<><StatusBadge status={o.status} /><StatusBadge status={o.payment_status} />{cancellable && <Button variant="danger" onClick={() => setCancel(true)}>Cancel order</Button>}</>} />
      {o.status === 'cancelled' && <p className="banner banner-warn">Cancelled {o.cancelled_at ? dateTime(o.cancelled_at) : ''}{o.cancelled_by_role ? ` by ${o.cancelled_by_role}` : ''}. Reason: {o.cancelled_reason ?? '—'}</p>}
      <div className="grid two">
        <Card title="Customer">
          {o.customer ? <KeyValue rows={[['Name', <Link key="n" to={`/customers/${o.customer.id}`}>{o.customer.full_name ?? 'Customer'}</Link>], ['Phone', o.customer.phone ?? '—'], ['E-mail', o.customer.email ?? '—'], ['Delivery address', address(o.delivery_address)], ['Customer note', o.customer_note ?? '—']]} />
            : <p className="muted">Customer details are unavailable.</p>}
        </Card>
        <Card title="Payment and totals">
          <KeyValue rows={[
            ['Method', o.payment_method === 'cod' ? 'Cash on delivery' : 'Online'],
            ['Payment status', <StatusBadge key="p" status={o.payment_status} />],
            ['Subtotal', money(o.subtotal)], ['Delivery charge', money(o.delivery_charge)], ['Discount', `${money(o.discount_amount)}${o.coupon_code ? ` (coupon ${o.coupon_code})` : ''}`],
            ['Order total', <strong key="t">{money(o.total_amount)}</strong>], ['Payment due by', o.payment_due_at ? dateTime(o.payment_due_at) : '—'],
          ]} />
        </Card>
      </div>

      <h2 className="section-gap">Vendor orders ({o.vendor_orders.length})</h2>
      <p className="muted small">{o.vendor_orders.length > 1 ? 'This order contains items from several vendors; each vendor fulfils its own part.' : 'This order has a single vendor.'}</p>
      {o.vendor_orders.map((v) => (
        <Card key={v.id} title={<><Link to={`/vendors/${v.vendor_id}`}>{v.vendor_name ?? 'Vendor'}</Link> <span className="muted small">{v.vendor_order_number}</span></>}
          actions={<><StatusBadge status={v.status} />{ACTIVE_VENDOR.includes(v.status) && <Button size="sm" onClick={() => setCancelVo(v)}>Cancel this vendor order</Button>}</>}>
          <DataTable caption={`Items from ${v.vendor_name}`} rows={v.items} rowKey={(i) => i.id}
            columns={[
              { key: 'n', header: 'Product', render: (i) => <>{i.product_name}<div className="muted small">{[i.product_brand, i.product_model, i.product_condition && humanize(i.product_condition)].filter(Boolean).join(' · ')}</div></> },
              { key: 'q', header: 'Qty', align: 'right', render: (i) => i.quantity },
              { key: 'u', header: 'Price at purchase', align: 'right', render: (i) => money(i.unit_price) },
              { key: 'l', header: 'Line total', align: 'right', render: (i) => money(i.line_total) },
            ]} />
          <KeyValue rows={[['Subtotal', money(v.subtotal)], ['Delivery', money(v.delivery_charge)], ['Discount', money(v.discount_amount)], ['Vendor order total', money(v.total_amount)],
            ['Accepted', v.accepted_at ? dateTime(v.accepted_at) : '—'], ['Delivered', v.delivered_at ? dateTime(v.delivered_at) : '—'],
            ...(v.rejection_reason ? [['Rejection reason', v.rejection_reason] as [string, string]] : []), ...(v.cancellation_reason ? [['Cancellation reason', v.cancellation_reason] as [string, string]] : [])]} />
        </Card>
      ))}

      <div className="grid two">
        <Card title="Transactions">
          <DataTable caption="Payments" rows={o.payments} rowKey={(p) => p.id} emptyTitle="No payment record"
            columns={[
              { key: 'm', header: 'Method', render: (p) => (p.method === 'cod' ? 'Cash on delivery' : 'Online') },
              { key: 'a', header: 'Amount', align: 'right', render: (p) => money(p.amount) },
              { key: 's', header: 'Status', render: (p) => <StatusBadge status={p.status} /> },
              { key: 'l', header: '', render: (p) => <Link to={`/payments/${p.id}`}>Details</Link> },
            ]} />
          {o.refunds.length > 0 && <>
            <h3 className="section-gap">Refunds</h3>
            <DataTable caption="Refunds" rows={o.refunds} rowKey={(r) => r.id}
              columns={[{ key: 'a', header: 'Amount', align: 'right', render: (r) => money(r.amount) }, { key: 's', header: 'Status', render: (r) => <StatusBadge status={r.status} /> }, { key: 'r', header: 'Reason', render: (r) => r.reason ?? '—' }]} />
          </>}
        </Card>
        <Card title="Complaints and disputes"><TicketsPanel state={tickets} /></Card>
      </div>
      <Card title="Status history"><Timeline state={timeline} /></Card>

      {cancel && (
        <ConfirmDialog title={`Cancel order ${o.order_number}?`} danger confirmLabel="Cancel order" reasonLabel="Reason (recorded with the order)" reasonRequired
          message="Reserved stock is returned once, and a refund is requested automatically if the customer already paid. This cannot be undone."
          onConfirm={async (reason) => { await s.orders.cancel(o.id, reason); toast.success('Order cancelled.'); refresh() }} onClose={() => setCancel(false)} />
      )}
      {cancelVo && (
        <ConfirmDialog title={`Cancel ${cancelVo.vendor_order_number}?`} danger confirmLabel="Cancel vendor order" reasonLabel="Reason" reasonRequired
          message={`Only ${cancelVo.vendor_name ?? 'this vendor'}'s part of the order is cancelled. Delivery is never marked complete from here: only the vendor's fulfilment updates do that.`}
          onConfirm={async (reason) => { await s.orders.setVendorOrderStatus(o.id, cancelVo.id, 'cancelled', reason); toast.success('Vendor order cancelled.'); refresh() }} onClose={() => setCancelVo(null)} />
      )}
    </>
  )
}
