import { useState } from 'react'
import { useServices } from '../../app/providers/authContext'
import { Button, Card, KeyValue, MetricCard, Modal, Pagination, SelectFilter, StatusBadge } from '../../components/common/ui'
import { DateRange } from '../../components/common/filters'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import type { SettlementRecord } from '../../types/api'
import { dateOnly, dateTime, humanize, money, shortId } from '../../utils/format'

const LIMIT = 20
const STATUS_HELP: Record<string, string> = { pending: 'Waiting for the customer’s payment to be confirmed', ready: 'Payment confirmed: owed to the vendor', paid: 'Recorded as paid outside this system', cancelled: 'Cancelled with the order' }

export function SettlementsPage() {
  const s = useServices()
  const { values, page, set, setPage } = useListQuery(['vendor_id', 'status', 'date_from', 'date_to'] as const)
  const vendors = useAsync(() => s.vendors.list({ verification_status: 'approved', limit: 100 }), [])
  const list = useAsync(() => s.settlements.list({ vendor_id: values.vendor_id, status: values.status, date_from: values.date_from, date_to: values.date_to, page, limit: LIMIT }), [values.vendor_id, values.status, values.date_from, values.date_to, page])
  const [open, setOpen] = useState<SettlementRecord | null>(null)
  const sum = list.data?.summary

  const columns: Column<SettlementRecord>[] = [
    { key: 'id', header: 'Settlement', render: (r) => <strong>{shortId(r.id)}</strong> },
    { key: 'v', header: 'Vendor', render: (r) => r.vendor_name ?? '—' },
    { key: 'o', header: 'Order', render: (r) => r.order_number ?? '—' },
    { key: 'g', header: 'Gross', align: 'right', render: (r) => money(r.gross_amount) },
    { key: 'c', header: 'Commission', align: 'right', render: (r) => money(r.commission_amount) },
    { key: 'd', header: 'Other deductions', align: 'right', render: (r) => money(r.deductions_amount) },
    { key: 'n', header: 'Net payable', align: 'right', render: (r) => <strong>{money(r.net_amount)}</strong> },
    { key: 's', header: 'Status', render: (r) => <StatusBadge status={r.status} /> },
    { key: 'dt', header: 'Created', render: (r) => dateOnly(r.created_at) },
    { key: 'sd', header: 'Settled', render: (r) => (r.settled_at ? dateOnly(r.settled_at) : '—') },
  ]

  return (
    <>
      <PageHeader title="Vendor settlements" subtitle="What each vendor earned after commission. Records only." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Vendor settlements' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <p className="note">These are settlement <strong>records</strong> calculated by the backend from delivered orders. The platform does not transfer money to vendors: “Paid” only means finance recorded a payout made elsewhere.</p>
      <div className="grid metrics">
        <MetricCard label="Waiting for payment" value={sum ? money(sum.pending ?? 0) : '…'} hint={STATUS_HELP.pending} tone="warn" />
        <MetricCard label="Ready to pay vendors" value={sum ? money(sum.ready ?? 0) : '…'} hint={STATUS_HELP.ready} tone="good" />
        <MetricCard label="Recorded as paid" value={sum ? money(sum.paid ?? 0) : '…'} hint={STATUS_HELP.paid} />
      </div>
      <Card>
        <div className="toolbar">
          <SelectFilter label="Vendor" value={values.vendor_id} onChange={(v) => set({ vendor_id: v })} options={[{ value: '', label: 'All vendors' }, ...(vendors.data?.items ?? []).map((v) => ({ value: v.id, label: v.business_name }))]} />
          <SelectFilter label="Status" value={values.status} onChange={(v) => set({ status: v })} options={[{ value: '', label: 'All' }, ...['pending', 'ready', 'paid', 'cancelled'].map((v) => ({ value: v, label: humanize(v) }))]} />
          <DateRange from={values.date_from} to={values.date_to} onChange={(r) => set({ date_from: r.from, date_to: r.to })} />
        </div>
        <p className="muted small">The totals above cover all settlements for the selected vendor, not just this page or date range.</p>
        <DataTable caption="Settlements" columns={columns} rows={list.data?.items ?? null} rowKey={(r) => r.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={setOpen} emptyTitle="No settlement records" emptyMessage="A record is created when a vendor order is delivered." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
      {open && (
        <Modal title={`Settlement ${shortId(open.id)}`} onClose={() => setOpen(null)} footer={<Button onClick={() => setOpen(null)}>Close</Button>}>
          <KeyValue rows={[['Vendor', open.vendor_name ?? '—'], ['Vendor order', open.order_number ?? '—'], ['Status', <StatusBadge key="s" status={open.status} />], ['Meaning', STATUS_HELP[open.status]],
            ['Gross', money(open.gross_amount)], ['Commission', money(open.commission_amount)], ['Other deductions', money(open.deductions_amount)], ['Net payable', <strong key="n">{money(open.net_amount)}</strong>],
            ['Created', dateTime(open.created_at)], ['Settled', open.settled_at ? dateTime(open.settled_at) : '—'], ['Payout reference', open.payout_reference ?? '—'], ['Notes', open.notes ?? '—']]} />
        </Modal>
      )}
    </>
  )
}
