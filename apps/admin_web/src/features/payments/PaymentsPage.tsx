import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { Button, Card, ErrorState, MetricCard, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { DateRange } from '../../components/common/filters'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import type { CountValue, PaymentRecord } from '../../types/api'
import { dateTime, isoDay, money, shortId } from '../../utils/format'
import { METHODS, PAYMENT_STATUSES } from '../../utils/options'

const LIMIT = 20

interface PaymentsReport {
  by_status: Record<string, CountValue>
  collected: number
  collected_by_method: Record<string, CountValue>
  refunded: number
  commission: number
}

function Overview() {
  const s = useServices()
  const [days, setDays] = useState('30')
  const range = () => { const to = new Date(); const from = new Date(); from.setDate(to.getDate() - (Number(days) - 1)); return { from: isoDay(from), to: isoDay(to) } }
  const rep = useAsync(() => { const r = range(); return s.reports.get<PaymentsReport>('payments', r.from, r.to) }, [days]) // eslint-disable-line react-hooks/exhaustive-deps
  const sum = useAsync(() => { const r = range(); return s.payments.summary(`${r.from}T00:00:00+05:30`, `${r.to}T23:59:59+05:30`) }, [days]) // eslint-disable-line react-hooks/exhaustive-deps
  const d = rep.data?.data
  const count = (k: string) => d?.by_status[k]?.count ?? 0
  return (
    <Card title="Payment overview" actions={<SelectFilter label="Period" value={days} onChange={setDays} options={[{ value: '7', label: 'Last 7 days' }, { value: '30', label: 'Last 30 days' }, { value: '90', label: 'Last 90 days' }]} />}>
      {rep.error && !d ? <ErrorState compact error={rep.error} onRetry={rep.reload} /> : (
        <div className="grid metrics">
          <MetricCard label="Online collected" value={d ? money(d.collected_by_method.online?.amount ?? 0) : '…'} hint={`${d?.collected_by_method.online?.count ?? 0} successful online payments`} tone="good" />
          <MetricCard label="Cash on delivery collected" value={d ? money(d.collected_by_method.cod?.amount ?? 0) : '…'} hint="Only cash an admin recorded as collected" />
          <MetricCard label="COD still to collect" value={sum.data ? money(sum.data.cod_outstanding) : '…'} hint="Pending COD on confirmed orders" tone="warn" />
          <MetricCard label="Pending payments" value={d ? count('pending') + count('processing') : '…'} hint={d ? money((d.by_status.pending?.amount ?? 0) + (d.by_status.processing?.amount ?? 0)) : undefined} tone="warn" />
          <MetricCard label="Failed payments" value={d ? count('failed') : '…'} tone="bad" />
          <MetricCard label="Refunded (processed)" value={d ? money(d.refunded) : '…'} hint="Only refunds confirmed as processed" />
          <MetricCard label="Platform commission" value={d ? money(d.commission) : '…'} hint="On orders delivered in the period" />
        </div>
      )}
      <p className="muted small">Figures count payments created in the period (collections and refunds follow the day the money moved). Failed or uncollected cash-on-delivery payments are never counted as collected.</p>
    </Card>
  )
}

export function PaymentsPage() {
  const s = useServices()
  const nav = useNavigate()
  const { values, page, set, setPage } = useListQuery(['q', 'status', 'method', 'date_from', 'date_to', 'needs_review'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const list = useAsync(() => s.payments.list({ q: values.q, status: values.status, method: values.method, date_from: values.date_from, date_to: values.date_to, needs_review: values.needs_review, page, limit: LIMIT }),
    [values.q, values.status, values.method, values.date_from, values.date_to, values.needs_review, page])

  const columns: Column<PaymentRecord>[] = [
    { key: 'ref', header: 'Payment', render: (p) => <Link to={`/payments/${p.id}`} onClick={(e) => e.stopPropagation()}><strong>{p.provider_order_id ?? shortId(p.id)}</strong></Link> },
    { key: 'o', header: 'Order', render: (p) => (p.order_id ? <Link to={`/orders/${p.order_id}`} onClick={(e) => e.stopPropagation()}>{p.order_number ?? '—'}</Link> : '—') },
    { key: 'c', header: 'Customer', render: (p) => p.customer_name ?? '—' },
    { key: 'm', header: 'Method', render: (p) => (p.method === 'cod' ? 'Cash on delivery' : 'Online') },
    { key: 'a', header: 'Amount', align: 'right', render: (p) => money(p.amount) },
    { key: 'd', header: 'Date', render: (p) => dateTime(p.paid_at ?? p.created_at) },
    { key: 's', header: 'Status', render: (p) => <><StatusBadge status={p.status} />{p.needs_review && <div className="muted small" title={p.review_reason ?? ''}>Needs review</div>}</> },
    { key: 'pr', header: 'Provider ref', render: (p) => <span className="small">{p.provider_payment_id ?? '—'}</span> },
  ]

  return (
    <>
      <PageHeader title="Payments" subtitle="Every payment and transaction on the platform." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Payments' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <Overview />
      <Card title="Transactions">
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search transaction reference, order or customer" />
          <SelectFilter label="Status" value={values.status} onChange={(v) => set({ status: v })} options={PAYMENT_STATUSES} />
          <SelectFilter label="Method" value={values.method} onChange={(v) => set({ method: v })} options={METHODS} />
          <SelectFilter label="Review" value={values.needs_review} onChange={(v) => set({ needs_review: v })} options={[{ value: '', label: 'All' }, { value: 'true', label: 'Needs review' }]} />
          <DateRange from={values.date_from} to={values.date_to} onChange={(r) => set({ date_from: r.from, date_to: r.to })} />
        </div>
        <DataTable caption="Payments" columns={columns} rows={list.data?.items ?? null} rowKey={(p) => p.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={(p) => nav(`/payments/${p.id}`)} emptyTitle="No payments found" emptyMessage="Try changing the search or filters." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
