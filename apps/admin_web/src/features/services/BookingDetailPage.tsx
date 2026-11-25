import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, EmptyState, ErrorState, KeyValue, PageLoading, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { useAsync } from '../../hooks/useAsync'
import { ApiError } from '../../services/api/client'
import type { BookingDetail } from '../../types/api'
import { dateOnly, dateTime, humanize, money } from '../../utils/format'
import { Timeline } from '../common/Timeline'
import { TicketsPanel } from '../support/TicketsPanel'

const OPEN = ['pending', 'accepted', 'picked_up', 'in_service', 'ready_for_delivery']
const addr = (a: Record<string, string | undefined> | undefined) => (a ? [a.recipient_name, a.address_line1, a.address_line2, a.landmark, [a.city, a.state, a.postal_code].filter(Boolean).join(' '), a.phone].filter(Boolean).join(', ') : '—')

export function BookingDetailPage() {
  const { id = '' } = useParams()
  const s = useServices()
  const toast = useToast()
  const booking = useAsync(() => s.bookings.get(id), [id])
  const timeline = useAsync(() => s.bookings.timeline(id), [id])
  const tickets = useAsync(() => s.bookings.tickets(id), [id])
  const [action, setAction] = useState<'reject' | 'cancel' | null>(null)

  if (booking.loading && !booking.data) return <PageLoading />
  if (booking.error && !booking.data) {
    const missing = booking.error instanceof ApiError && booking.error.kind === 'not_found'
    return missing ? <Card><EmptyState title="Booking not found" action={<Link to="/service-bookings">Back to bookings</Link>} /></Card> : <ErrorState error={booking.error} onRetry={booking.reload} />
  }
  const b = booking.data as BookingDetail
  const refresh = () => { booking.reload(); timeline.reload() }
  const sched = (x: BookingDetail['preferred']) => (x?.date ? `${dateOnly(x.date)} ${x.slot_start?.slice(0, 5) ?? ''}${x.slot_end ? `–${x.slot_end.slice(0, 5)}` : ''}` : '—')
  const pk = b.pickup

  return (
    <>
      <PageHeader title={`Booking ${b.booking_number}`} subtitle={`${b.service_name} · ${b.vendor_name ?? ''}`} crumbs={[{ label: 'Overview', to: '/' }, { label: 'Service bookings', to: '/service-bookings' }, { label: b.booking_number }]}
        actions={<><StatusBadge status={b.status} />{b.status === 'pending' && <Button onClick={() => setAction('reject')}>Reject</Button>}{OPEN.includes(b.status) && <Button variant="danger" onClick={() => setAction('cancel')}>Cancel booking</Button>}</>} />
      {(b.rejection_reason || b.cancellation_reason) && <p className="banner banner-warn">{b.rejection_reason ? `Rejected: ${b.rejection_reason}` : `Cancelled: ${b.cancellation_reason}`}</p>}
      <p className="note">Repair notes, charges and progress belong to the vendor and are shown read-only. An administrator can reject a pending booking or cancel an open one, with a recorded reason.</p>
      <div className="grid two">
        <Card title="Customer">
          <KeyValue rows={[['Name', <Link key="c" to={`/customers/${b.customer_id}`}>{b.customer?.full_name ?? 'Customer'}</Link>], ['Phone', b.customer?.phone ?? '—']]} />
        </Card>
        <Card title="Vendor">
          <KeyValue rows={[['Business', b.vendor_admin ? <Link key="v" to={`/vendors/${b.vendor_admin.id}`}>{b.vendor_admin.business_name}</Link> : b.vendor_name ?? '—'], ['Verification', <StatusBadge key="vs" status={b.vendor_admin?.verification_status} />],
            ['Location', [b.vendor_admin?.city, b.vendor_admin?.state].filter(Boolean).join(', ') || '—'], ['Phone', b.vendor_admin?.contact_phone ?? '—']]} />
        </Card>
      </div>
      <div className="grid two">
        <Card title="Service and cycle">
          <KeyValue rows={[['Service', b.service_name], ['Category', b.service_category?.name ?? '—'], ['Cycle', [b.cycle?.brand, b.cycle?.model].filter(Boolean).join(' ') || '—'], ['Cycle details', b.cycle?.details ?? '—'],
            ['Issue described by customer', b.issue_description], ['Estimated duration', b.estimated_duration_minutes ? `${b.estimated_duration_minutes} min` : '—']]} />
        </Card>
        <Card title="Schedule">
          <KeyValue rows={[['Preferred', sched(b.preferred)], ['Confirmed appointment', sched(b.confirmed)], ['Accepted', b.accepted_at ? dateTime(b.accepted_at) : '—'], ['Completed', b.completed_at ? dateTime(b.completed_at) : '—'], ['Completion notes', b.completion_notes ?? '—']]} />
        </Card>
      </div>
      <div className="grid two">
        <Card title="Charges">
          <KeyValue rows={[['Estimate (quoted when booked)', money(b.pricing.estimated_price)], ['Additional repair charges', money(b.pricing.additional_charges_total)], ['Current service price', money(b.pricing.current_price)],
            ['Pickup charge', money(b.pricing.pickup_charge)], ['Drop-off charge', money(b.pricing.dropoff_charge)], ['Total now', <strong key="t">{money(b.pricing.total_current)}</strong>]]} />
          {b.pricing.logistics_charges_configured === false && b.needs_pickup_dropoff && <p className="muted small">Pickup/drop-off charges are not configured in Settings, so they are recorded as ₹0.</p>}
          {b.charges.length > 0 && <ul className="list">{b.charges.map((c) => <li key={c.id}><span>{c.reason}<br /><span className="muted small">{dateTime(c.created_at)} · {humanize(c.recorded_role)}</span></span><strong>{money(c.amount)}</strong></li>)}</ul>}
        </Card>
        <Card title="Service notes (vendor)">
          {b.notes.length === 0 ? <p className="muted">No notes recorded.</p> : <ul className="list">{b.notes.map((n) => <li key={n.id}><span>{n.note}<br /><span className="muted small">{dateTime(n.created_at)} · {humanize(n.author_role)}</span></span></li>)}</ul>}
        </Card>
      </div>
      <Card title="Pickup and drop-off">
        {!pk ? <p className="muted">{b.needs_pickup_dropoff ? 'No pickup request was recorded.' : 'The customer did not request doorstep pickup.'}</p> : (
          <KeyValue rows={[['Pickup status', <StatusBadge key="ps" status={pk.pickup_status} label={humanize(pk.pickup_stage)} />], ['Pickup address', addr(pk.pickup_address)], ['Pickup scheduled', pk.scheduled_pickup_at ? dateTime(pk.scheduled_pickup_at) : '—'], ['Picked up', pk.picked_up_at ? dateTime(pk.picked_up_at) : '—'],
            ['Drop-off status', <StatusBadge key="ds" status={pk.delivery_status} label={humanize(pk.delivery_stage)} />], ['Drop-off address', addr(pk.dropoff_address)], ['Drop-off scheduled', pk.scheduled_delivery_at ? dateTime(pk.scheduled_delivery_at) : '—'], ['Delivered back', pk.delivered_at ? dateTime(pk.delivered_at) : '—'],
            ['Customer instructions', pk.customer_instructions ?? '—'], ['Coordination notes', pk.notes ?? '—']]} />
        )}
        {pk && <p className="small section-gap"><Link to={`/pickups?q=${encodeURIComponent(b.booking_number)}`}>Coordinate this pickup</Link></p>}
      </Card>
      <Card title={`Cycle photos (${b.images.length})`}>
        {b.images.length === 0 ? <p className="muted">The customer did not attach photos.</p> : <div className="gallery">{b.images.map((im) => (im.url ? <img key={im.id} src={im.url} alt="Cycle photo from the customer" /> : <span key={im.id} className="muted">Image unavailable</span>))}</div>}
      </Card>
      <div className="grid two">
        <Card title="Repair status history"><Timeline state={timeline} /></Card>
        <Card title="Complaints and disputes"><TicketsPanel state={tickets} /></Card>
      </div>
      {action && (
        <ConfirmDialog title={action === 'reject' ? `Reject ${b.booking_number}?` : `Cancel ${b.booking_number}?`} danger confirmLabel={action === 'reject' ? 'Reject booking' : 'Cancel booking'} reasonLabel="Reason (shown to the customer and recorded)" reasonRequired
          message={action === 'reject' ? 'The customer is told the booking was rejected.' : 'The booking is closed. Its record, charges and history are kept.'}
          onConfirm={async (reason) => { await s.bookings.setStatus(b.id, action === 'reject' ? 'rejected' : 'cancelled', reason); toast.success(action === 'reject' ? 'Booking rejected.' : 'Booking cancelled.'); refresh() }} onClose={() => setAction(null)} />
      )}
    </>
  )
}
