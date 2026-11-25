import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, Modal, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { SelectField, TextAreaField, TextField } from '../../components/forms/fields'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import { errorMessage } from '../../services/api/client'
import type { PickupItem } from '../../types/api'
import { dateTime, humanize, money } from '../../utils/format'

const LIMIT = 20
const LOGISTICS = [{ value: '', label: 'All' }, ...['pending', 'scheduled', 'completed', 'failed', 'cancelled'].map((v) => ({ value: v, label: humanize(v) }))]
const SETTABLE = [{ value: '', label: 'No change' }, { value: 'scheduled', label: 'Scheduled' }, { value: 'failed', label: 'Failed' }, { value: 'cancelled', label: 'Cancelled' }]
const addr = (a: Record<string, string | undefined>) => [a.address_line1, a.landmark, [a.city, a.postal_code].filter(Boolean).join(' ')].filter(Boolean).join(', ') || '—'
const pad = (n: number) => String(n).padStart(2, '0')
const toLocal = (iso: string | null) => { if (!iso) return ''; const d = new Date(iso); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}` }

function Coordinate({ item, onClose, onSaved }: { item: PickupItem; onClose: () => void; onSaved: () => void }) {
  const s = useServices()
  const toast = useToast()
  const p = item.pickup
  const [pickupAt, setPickupAt] = useState(toLocal(p.scheduled_pickup_at))
  const [deliverAt, setDeliverAt] = useState(toLocal(p.scheduled_delivery_at))
  const [pickupStatus, setPickupStatus] = useState('')
  const [deliveryStatus, setDeliveryStatus] = useState('')
  const [notes, setNotes] = useState(p.notes ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const problem = (pickupStatus === 'scheduled' && !pickupAt) ? 'Choose the pickup time to schedule it.' : (deliveryStatus === 'scheduled' && !deliverAt) ? 'Choose the return time to schedule it.' : null
  async function save() {
    if (problem) { setError(problem); return }
    const body: Parameters<typeof s.pickups.coordinate>[1] = {}
    if (pickupAt !== toLocal(p.scheduled_pickup_at) && pickupAt) body.scheduled_pickup_at = new Date(pickupAt).toISOString()
    if (deliverAt !== toLocal(p.scheduled_delivery_at) && deliverAt) body.scheduled_delivery_at = new Date(deliverAt).toISOString()
    if (pickupStatus) body.pickup_status = pickupStatus
    if (deliveryStatus) body.delivery_status = deliveryStatus
    if (notes !== (p.notes ?? '')) body.notes = notes
    if (!Object.keys(body).length) { setError('Nothing was changed.'); return }
    setBusy(true)
    setError(null)
    try {
      await s.pickups.coordinate(item.id, body)
      toast.success('Pickup / drop-off updated.')
      onSaved()
      onClose()
    } catch (e) {
      setError(errorMessage(e))
      setBusy(false)
    }
  }
  return (
    <Modal title={`Coordinate ${item.booking_number ?? 'pickup'}`} wide onClose={busy ? () => undefined : onClose} footer={<><Button onClick={onClose} disabled={busy}>Cancel</Button><Button variant="primary" busy={busy} onClick={() => void save()}>Save</Button></>}>
      <p className="muted small">Completion is recorded when the vendor moves the booking to “picked up” or “completed”; it cannot be set here. Booking status: <StatusBadge status={item.booking_status} /></p>
      <div className="form-grid">
        <TextField label="Pickup time" type="datetime-local" value={pickupAt} onChange={setPickupAt} />
        <SelectField label="Pickup status" value={pickupStatus} onChange={setPickupStatus} options={SETTABLE} help={`Now: ${humanize(p.pickup_stage)}`} />
        <TextField label="Return delivery time" type="datetime-local" value={deliverAt} onChange={setDeliverAt} />
        <SelectField label="Return status" value={deliveryStatus} onChange={setDeliveryStatus} options={SETTABLE} help={`Now: ${humanize(p.delivery_stage)}`} />
      </div>
      <TextAreaField label="Coordination notes" value={notes} onChange={setNotes} maxLength={500} help="Visible to the vendor handling the booking." />
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

export function PickupsPage() {
  const s = useServices()
  const { values, page, set, setPage } = useListQuery(['q', 'pickup_status', 'delivery_status'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const list = useAsync(() => s.pickups.list({ q: values.q, pickup_status: values.pickup_status, delivery_status: values.delivery_status, page, limit: LIMIT }), [values.q, values.pickup_status, values.delivery_status, page])
  const [open, setOpen] = useState<PickupItem | null>(null)

  const columns: Column<PickupItem>[] = [
    { key: 'b', header: 'Booking', render: (r) => <Link to={`/service-bookings/${r.booking_id}`}><strong>{r.booking_number}</strong></Link> },
    { key: 'c', header: 'Customer', render: (r) => <>{r.customer?.full_name ?? '—'}<div className="muted small">{r.customer?.phone ?? ''}</div></> },
    { key: 'v', header: 'Vendor', render: (r) => r.vendor_name ?? '—' },
    { key: 'pa', header: 'Pickup from', render: (r) => <span className="small">{addr(r.pickup.pickup_address)}</span> },
    { key: 'pt', header: 'Pickup time', render: (r) => (r.pickup.scheduled_pickup_at ? dateTime(r.pickup.scheduled_pickup_at) : <span className="muted">Not scheduled</span>) },
    { key: 'ps', header: 'Pickup status', render: (r) => <StatusBadge status={r.pickup.pickup_status} label={humanize(r.pickup.pickup_stage)} /> },
    { key: 'da', header: 'Return to', render: (r) => <span className="small">{addr(r.pickup.dropoff_address)}</span> },
    { key: 'dt', header: 'Return time', render: (r) => (r.pickup.scheduled_delivery_at ? dateTime(r.pickup.scheduled_delivery_at) : <span className="muted">Not scheduled</span>) },
    { key: 'ds', header: 'Return status', render: (r) => <StatusBadge status={r.pickup.delivery_status} label={humanize(r.pickup.delivery_stage)} /> },
    { key: 'ch', header: 'Charges', align: 'right', render: (r) => <span title="pickup + drop-off">{money(r.pickup.pickup_charge + r.pickup.dropoff_charge)}</span> },
    { key: 'bs', header: 'Booking status', render: (r) => <StatusBadge status={r.booking_status} /> },
    { key: 'a', header: '', align: 'right', render: (r) => <Button size="sm" onClick={() => setOpen(r)}>Coordinate</Button> },
  ]

  return (
    <>
      <PageHeader title="Pickup & drop-off" subtitle="Doorstep pickup and return requests. Coordination only: there is no rider app or live tracking." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Pickup & drop-off' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search booking number, customer or vendor" />
          <SelectFilter label="Pickup status" value={values.pickup_status} onChange={(v) => set({ pickup_status: v })} options={LOGISTICS} />
          <SelectFilter label="Return status" value={values.delivery_status} onChange={(v) => set({ delivery_status: v })} options={LOGISTICS} />
        </div>
        <p className="muted small">Pickup/return status is tracked separately from the booking status.</p>
        <DataTable caption="Pickup and drop-off requests" columns={columns} rows={list.data?.items ?? null} rowKey={(r) => r.id} loading={list.loading} error={list.error} onRetry={list.reload}
          emptyTitle="No pickup requests" emptyMessage="Bookings that need doorstep pickup appear here." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
      {open && <Coordinate item={open} onClose={() => setOpen(null)} onSaved={list.reload} />}
    </>
  )
}
