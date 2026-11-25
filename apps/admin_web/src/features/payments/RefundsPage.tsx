import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, Modal, Pagination, SearchInput, StatusBadge } from '../../components/common/ui'
import { Tabs, DateRange } from '../../components/common/filters'
import { CheckField, TextAreaField, TextField } from '../../components/forms/fields'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import { errorMessage } from '../../services/api/client'
import type { RefundRecord } from '../../types/api'
import { dateTime, money, shortId } from '../../utils/format'

const LIMIT = 20
type ActionName = 'approve' | 'reject' | 'process' | 'fail'

function ActionDialog({ refund, action, providerReady, onClose, onDone }: { refund: RefundRecord; action: ActionName; providerReady: boolean; onClose: () => void; onDone: () => void }) {
  const s = useServices()
  const toast = useToast()
  const [manual, setManual] = useState(false)
  const [ref, setRef] = useState('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const needsNote = action === 'reject' || action === 'fail'
  const invalid = (needsNote && !note.trim()) || (action === 'process' && manual && ref.trim().length < 3) || (action === 'process' && !manual && !providerReady)
  const titles: Record<ActionName, string> = { approve: 'Approve this refund?', reject: 'Reject this refund?', process: 'Process this refund', fail: 'Mark this refund as failed?' }

  async function go() {
    setBusy(true)
    setError(null)
    try {
      const out = await s.refunds.act(refund.id, { action, ...(action === 'process' ? { manual, provider_refund_id: manual ? ref.trim() : undefined } : {}), note: note.trim() || undefined })
      toast.success(out.status === 'processed' ? 'Refund recorded as processed.' : out.status === 'approved' && action === 'process' ? 'The provider has the request; it stays “approved” until the provider confirms.' : 'Refund updated.')
      onDone()
      onClose()
    } catch (e) {
      setError(errorMessage(e))
      setBusy(false)
    }
  }
  return (
    <Modal title={titles[action]} onClose={busy ? () => undefined : onClose} footer={<><Button onClick={onClose} disabled={busy}>Cancel</Button><Button variant={action === 'reject' || action === 'fail' ? 'danger' : 'primary'} busy={busy} disabled={invalid} onClick={() => void go()}>{{ approve: 'Approve', reject: 'Reject', process: 'Process', fail: 'Mark as failed' }[action]}</Button></>}>
      <p>{money(refund.amount)} for order {refund.order_number ?? '—'}. Reason given: {refund.reason ?? '—'}.</p>
      {action === 'process' && (
        <>
          <p className="muted small">A refund is marked processed only after the provider confirms it, or after you record a refund finance already paid outside this system (with its payment reference).</p>
          {!providerReady && <p className="note">No payment provider is configured on the server, so a provider refund is unavailable. Use a manual record below if the money was already paid back.</p>}
          <CheckField label="This refund was already paid outside the system" checked={manual} onChange={setManual} />
          {manual && <TextField label="External payment reference" required value={ref} onChange={setRef} help="Bank / transfer reference, at least 3 characters." />}
        </>
      )}
      {(needsNote || action === 'approve') && <TextAreaField label={needsNote ? 'Reason' : 'Note (optional)'} required={needsNote} value={note} onChange={setNote} maxLength={500} />}
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

export function RefundsPage() {
  const s = useServices()
  const { values, page, set, setPage } = useListQuery(['q', 'status', 'date_from', 'date_to'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const provider = useAsync(() => s.payments.provider(), [])
  const list = useAsync(() => s.refunds.list({ q: values.q, status: values.status, date_from: values.date_from, date_to: values.date_to, page, limit: LIMIT }), [values.q, values.status, values.date_from, values.date_to, page])
  const [pending, setPending] = useState<{ refund: RefundRecord; action: ActionName } | null>(null)
  const ready = provider.data?.configured === true

  const columns: Column<RefundRecord>[] = [
    { key: 'id', header: 'Refund', render: (r) => <strong>{shortId(r.id)}</strong> },
    { key: 'o', header: 'Order', render: (r) => (r.order_id ? <Link to={`/orders/${r.order_id}`}>{r.order_number ?? '—'}</Link> : '—') },
    { key: 'p', header: 'Payment', render: (r) => <Link to={`/payments/${r.payment_id}`}>View</Link> },
    { key: 'a', header: 'Amount', align: 'right', render: (r) => money(r.amount) },
    { key: 'r', header: 'Reason', render: (r) => <span className="small">{r.reason ?? '—'}</span> },
    { key: 's', header: 'Status', render: (r) => <><StatusBadge status={r.status} />{r.failure_reason && <div className="muted small">{r.failure_reason}</div>}</> },
    { key: 'pr', header: 'Provider ref', render: (r) => <span className="small">{r.provider_refund_id ?? '—'}</span> },
    { key: 'd', header: 'Requested', render: (r) => dateTime(r.created_at) },
    { key: 'pd', header: 'Processed', render: (r) => (r.processed_at ? dateTime(r.processed_at) : '—') },
    { key: 'act', header: 'Actions', align: 'right', render: (r) => (
      <span className="row-actions">
        {(r.status === 'requested' || r.status === 'failed') && <Button size="sm" variant="primary" onClick={() => setPending({ refund: r, action: 'approve' })}>{r.status === 'failed' ? 'Retry (approve)' : 'Approve'}</Button>}
        {r.status === 'approved' && <Button size="sm" variant="primary" onClick={() => setPending({ refund: r, action: 'process' })}>Process</Button>}
        {r.status === 'approved' && <Button size="sm" onClick={() => setPending({ refund: r, action: 'fail' })}>Mark failed</Button>}
        {['requested', 'approved'].includes(r.status) && <Button size="sm" onClick={() => setPending({ refund: r, action: 'reject' })}>Reject</Button>}
      </span>) },
  ]

  return (
    <>
      <PageHeader title="Refunds" subtitle="Refund requests and their real status." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Refunds' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      {provider.data && !provider.data.configured && <p className="note">No online payment provider is configured on the server. Refunds can be requested and approved, but “Process” through a provider is unavailable until one is configured; a refund finance already paid can be recorded manually. Nothing is shown as refunded before it truly is.</p>}
      <Tabs label="Refund status" value={values.status} onChange={(v) => set({ status: v })} tabs={[{ value: '', label: 'All' }, ...['requested', 'approved', 'processed', 'rejected', 'failed'].map((v) => ({ value: v, label: v[0].toUpperCase() + v.slice(1) }))]} />
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search order number, provider reference or reason" />
          <DateRange from={values.date_from} to={values.date_to} onChange={(r) => set({ date_from: r.from, date_to: r.to })} />
        </div>
        <DataTable caption="Refunds" columns={columns} rows={list.data?.items ?? null} rowKey={(r) => r.id} loading={list.loading} error={list.error} onRetry={list.reload}
          emptyTitle="No refunds" emptyMessage="Refunds are requested from a payment's page, or automatically when a paid order is cancelled." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
      {pending && <ActionDialog refund={pending.refund} action={pending.action} providerReady={ready} onClose={() => setPending(null)} onDone={list.reload} />}
    </>
  )
}
