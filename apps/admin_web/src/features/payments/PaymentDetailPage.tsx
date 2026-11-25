import { useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, EmptyState, ErrorState, KeyValue, Modal, PageLoading, StatusBadge } from '../../components/common/ui'
import { TextAreaField, TextField } from '../../components/forms/fields'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { ApiError, errorMessage } from '../../services/api/client'
import { newIdempotencyKey } from '../../services/api/services'
import type { PaymentDetail } from '../../types/api'
import { dateTime, money } from '../../utils/format'

const REFUNDABLE = ['successful', 'partially_refunded']

function RefundForm({ payment, onClose, onSaved }: { payment: PaymentDetail; onClose: () => void; onSaved: () => void }) {
  const s = useServices()
  const toast = useToast()
  const key = useRef(newIdempotencyKey())           // one key per opened form: a double click can never create two refunds
  const max = Math.round((payment.amount - payment.refunded_amount) * 100) / 100
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [touched, setTouched] = useState(false)
  const n = Number(amount)
  const e: Record<string, string> = {}
  if (!amount.trim() || Number.isNaN(n) || n <= 0) e.amount = 'Enter an amount greater than zero.'
  else if (n > max) e.amount = `The most that can be refunded is ${money(max)}.`
  else if (!/^\d+(\.\d{1,2})?$/.test(amount.trim())) e.amount = 'Use at most two decimals.'
  if (reason.trim().length < 3) e.reason = 'Give a reason of at least 3 characters.'
  async function save() {
    setTouched(true)
    if (Object.keys(e).length) return
    setBusy(true)
    setError(null)
    try {
      await s.refunds.create({ payment_id: payment.id, amount: n, reason: reason.trim() }, key.current)
      toast.success('Refund requested. Nothing is refunded until it is approved and processed.')
      onSaved()
      onClose()
    } catch (err) {
      setError(errorMessage(err))
      setBusy(false)
    }
  }
  return (
    <Modal title="Request a refund" onClose={busy ? () => undefined : onClose} footer={<><Button onClick={onClose} disabled={busy}>Cancel</Button><Button variant="primary" busy={busy} onClick={() => void save()}>Request refund</Button></>}>
      <p className="muted small">Paid {money(payment.amount)}, already refunded {money(payment.refunded_amount)}. The server re-checks the limit, including refunds already requested.</p>
      <TextField label="Amount (₹)" required inputMode="decimal" value={amount} onChange={setAmount} error={touched ? e.amount : null} help={`Up to ${money(max)}`} />
      <TextAreaField label="Reason" required value={reason} onChange={setReason} maxLength={500} error={touched ? e.reason : null} />
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

export function PaymentDetailPage() {
  const { id = '' } = useParams()
  const s = useServices()
  const toast = useToast()
  const pay = useAsync(() => s.payments.get(id), [id])
  const provider = useAsync(() => s.payments.provider(), [])
  const [dialog, setDialog] = useState<'cod' | 'reconcile' | 'refund' | null>(null)

  if (pay.loading && !pay.data) return <PageLoading />
  if (pay.error && !pay.data) {
    const missing = pay.error instanceof ApiError && pay.error.kind === 'not_found'
    return missing ? <Card><EmptyState title="Payment not found" action={<Link to="/payments">Back to payments</Link>} /></Card> : <ErrorState error={pay.error} onRetry={pay.reload} />
  }
  const p = pay.data as PaymentDetail
  const canCollect = p.method === 'cod' && p.status === 'pending'
  const canReconcile = p.method === 'online' && ['pending', 'processing'].includes(p.status)
  const canRefund = REFUNDABLE.includes(p.status) && p.amount - p.refunded_amount > 0

  return (
    <>
      <PageHeader title={`Payment ${p.provider_order_id ?? p.id.slice(0, 8)}`} subtitle={`${p.method === 'cod' ? 'Cash on delivery' : 'Online'} · ${money(p.amount)}`}
        crumbs={[{ label: 'Overview', to: '/' }, { label: 'Payments', to: '/payments' }, { label: p.provider_order_id ?? p.id.slice(0, 8) }]}
        actions={<><StatusBadge status={p.status} />
          {canCollect && <Button variant="primary" onClick={() => setDialog('cod')}>Record cash collected</Button>}
          {canReconcile && <Button onClick={() => setDialog('reconcile')} disabled={provider.data?.configured === false} title={provider.data?.configured === false ? 'No payment provider is configured' : undefined}>Check with provider</Button>}
          {canRefund && <Button onClick={() => setDialog('refund')}>Request refund</Button>}</>} />
      {p.needs_review && <p className="banner banner-warn">This payment needs review: {p.review_reason ?? 'the amount or timing did not match the order.'}</p>}
      {provider.data && !provider.data.configured && <p className="note">No online payment provider is configured on the server, so provider checks and provider refunds are unavailable. Nothing is simulated.</p>}
      <div className="grid two">
        <Card title="Payment">
          <KeyValue rows={[['Status', <StatusBadge key="s" status={p.status} />], ['Method', p.method === 'cod' ? 'Cash on delivery' : 'Online'], ['Amount', money(p.amount)], ['Still to pay', money(p.amount_due)], ['Refunded so far', money(p.refunded_amount)],
            ['Created', dateTime(p.created_at)], ['Paid', p.paid_at ? dateTime(p.paid_at) : '—'], ['Failure reason', p.failure_reason ?? '—'], ['Recorded by', p.recorded_by ? 'An administrator (cash collection)' : '—']]} />
        </Card>
        <Card title="Order and customer">
          <KeyValue rows={[['Order', p.order ? <Link key="o" to={`/orders/${p.order.id}`}>{p.order.order_number}</Link> : '—'], ['Order status', p.order ? <StatusBadge key="os" status={p.order.status} /> : '—'], ['Order total', p.order ? money(p.order.total_amount) : '—'],
            ['Customer', <Link key="c" to={`/customers/${p.customer_id}`}>{p.customer_name ?? 'Customer'}</Link>], ['Provider', p.provider ?? '—'], ['Provider order reference', p.provider_order_id ?? '—'], ['Provider payment reference', p.provider_payment_id ?? '—']]} />
        </Card>
      </div>
      <Card title="Refunds on this payment">
        <DataTable caption="Refunds" rows={p.refunds} rowKey={(r) => r.id} emptyTitle="No refunds" columns={[
          { key: 'a', header: 'Amount', align: 'right', render: (r) => money(r.amount) }, { key: 's', header: 'Status', render: (r) => <StatusBadge status={r.status} /> },
          { key: 'r', header: 'Reason', render: (r) => r.reason ?? '—' }, { key: 'd', header: 'Requested', render: (r) => dateTime(r.created_at) }, { key: 'l', header: '', render: () => <Link to="/refunds">Manage</Link> }]} />
      </Card>
      <Card title="Provider events">
        <DataTable caption="Provider events" rows={p.events} rowKey={(e) => e.id} emptyTitle="No provider events" emptyMessage="Cash-on-delivery payments and payments not yet attempted have none." columns={[
          { key: 't', header: 'Event', render: (e) => e.event_type }, { key: 'o', header: 'Outcome', render: (e) => e.outcome }, { key: 'a', header: 'Amount', align: 'right', render: (e) => (e.amount === null ? '—' : money(e.amount)) }, { key: 'd', header: 'Received', render: (e) => dateTime(e.created_at) }]} />
      </Card>
      {dialog === 'cod' && (
        <ConfirmDialog title="Record cash collected?" confirmLabel="Record collection" message={<>Confirm that {money(p.amount)} cash was actually received for this order. This is the only way a cash-on-delivery payment becomes successful, and it makes the vendor's settlement ready. It cannot be undone.</>}
          onConfirm={async () => { await s.payments.collectCod(p.id); toast.success('Cash collection recorded.'); pay.reload() }} onClose={() => setDialog(null)} />
      )}
      {dialog === 'reconcile' && (
        <ConfirmDialog title="Check this payment with the provider?" confirmLabel="Check now" message="Asks the payment provider for the payment's true state and applies its answer through the same verified path as a webhook."
          onConfirm={async () => { await s.payments.reconcile(p.id); toast.success('Provider state applied.'); pay.reload() }} onClose={() => setDialog(null)} />
      )}
      {dialog === 'refund' && <RefundForm payment={p} onClose={() => setDialog(null)} onSaved={pay.reload} />}
    </>
  )
}
