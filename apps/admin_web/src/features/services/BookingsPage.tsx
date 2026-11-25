import { Link, useNavigate } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { Button, Card, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { DateRange } from '../../components/common/filters'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import type { BookingListItem } from '../../types/api'
import { dateOnly, humanize, money } from '../../utils/format'
import { BOOKING_STATUSES } from '../../utils/options'

const LIMIT = 20

export function BookingsPage() {
  const s = useServices()
  const nav = useNavigate()
  const { values, page, set, setPage } = useListQuery(['q', 'status', 'vendor_id', 'date_from', 'date_to'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const vendors = useAsync(() => s.vendors.list({ business_type: 'service_provider', limit: 100 }), [])
  const list = useAsync(() => s.bookings.list({ q: values.q, status: values.status, vendor_id: values.vendor_id, date_from: values.date_from, date_to: values.date_to, page, limit: LIMIT }),
    [values.q, values.status, values.vendor_id, values.date_from, values.date_to, page])

  const columns: Column<BookingListItem>[] = [
    { key: 'no', header: 'Booking', render: (b) => <Link to={`/service-bookings/${b.id}`} onClick={(e) => e.stopPropagation()}><strong>{b.booking_number}</strong></Link> },
    { key: 'c', header: 'Customer', render: (b) => <>{b.customer?.full_name ?? '—'}<div className="muted small">{b.customer?.phone ?? ''}</div></> },
    { key: 'v', header: 'Vendor', render: (b) => b.vendor_name ?? '—' },
    { key: 's', header: 'Service', render: (b) => <>{b.service_name}<div className="muted small">{b.service_category ?? ''}</div></> },
    { key: 'd', header: 'Booking date', render: (b) => <>{dateOnly(b.confirmed?.date ?? b.preferred.date)}<div className="muted small">{(b.confirmed?.slot_start ?? b.preferred.slot_start)?.slice(0, 5) ?? ''}{b.confirmed?.date ? ' (confirmed)' : ' (preferred)'}</div></> },
    { key: 'st', header: 'Booking status', render: (b) => <StatusBadge status={b.status} /> },
    { key: 'p', header: 'Pickup / drop-off', render: (b) => (b.needs_pickup_dropoff ? <>Required<div className="muted small">{b.pickup_stage ? `Pickup ${humanize(b.pickup_stage)}` : ''}{b.delivery_stage ? ` · Return ${humanize(b.delivery_stage)}` : ''}</div></> : <span className="muted">Not needed</span>) },
    { key: 'ch', header: 'Current charges', align: 'right', render: (b) => money(b.current_price) },
    { key: 'a', header: '', align: 'right', render: (b) => <Button size="sm" onClick={() => nav(`/service-bookings/${b.id}`)}>View</Button> },
  ]

  return (
    <>
      <PageHeader title="Service bookings" subtitle="Every servicing booking across all vendors." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Service bookings' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search booking number, customer or vendor" />
          <SelectFilter label="Status" value={values.status} onChange={(v) => set({ status: v })} options={BOOKING_STATUSES} />
          <SelectFilter label="Vendor" value={values.vendor_id} onChange={(v) => set({ vendor_id: v })} options={[{ value: '', label: 'All vendors' }, ...(vendors.data?.items ?? []).map((v) => ({ value: v.id, label: v.business_name }))]} />
          <DateRange from={values.date_from} to={values.date_to} onChange={(r) => set({ date_from: r.from, date_to: r.to })} />
        </div>
        <p className="muted small">Dates filter by the customer's preferred booking date.</p>
        <DataTable caption="Service bookings" columns={columns} rows={list.data?.items ?? null} rowKey={(b) => b.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={(b) => nav(`/service-bookings/${b.id}`)} emptyTitle="No bookings found" emptyMessage="Try changing the search or filters." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
