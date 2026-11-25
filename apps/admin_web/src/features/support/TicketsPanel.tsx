import { useState } from 'react'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, EmptyState, ErrorState, Modal, Spinner, StatusBadge } from '../../components/common/ui'
import { SelectField, TextAreaField } from '../../components/forms/fields'
import type { AsyncState } from '../../hooks/useAsync'
import { errorMessage } from '../../services/api/client'
import type { Page, Ticket } from '../../types/api'
import { dateTime, humanize } from '../../utils/format'

const STATUSES = [{ value: 'open', label: 'Open' }, { value: 'in_progress', label: 'In progress' }, { value: 'resolved', label: 'Resolved' }, { value: 'closed', label: 'Closed' }]

function Triage({ ticket, onClose, onSaved }: { ticket: Ticket; onClose: () => void; onSaved: () => void }) {
  const s = useServices()
  const toast = useToast()
  const [status, setStatus] = useState<string>(ticket.status)
  const [notes, setNotes] = useState(ticket.admin_notes ?? '')
  const [resolution, setResolution] = useState(ticket.resolution ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  async function save() {
    setBusy(true)
    setError(null)
    try {
      await s.tickets.update(ticket.id, { status, admin_notes: notes || undefined, resolution: resolution || undefined })
      toast.success('Ticket updated.')
      onSaved()
      onClose()
    } catch (e) {
      setError(errorMessage(e))
      setBusy(false)
    }
  }
  return (
    <Modal title={`${ticket.ticket_number}: ${ticket.subject}`} onClose={busy ? () => undefined : onClose}
      footer={<><Button onClick={onClose} disabled={busy}>Cancel</Button><Button variant="primary" busy={busy} onClick={() => void save()}>Save</Button></>}>
      <p>{ticket.description}</p>
      <SelectField label="Status" value={status} onChange={setStatus} options={STATUSES} />
      <TextAreaField label="Internal notes" value={notes} onChange={setNotes} maxLength={2000} help="Only administrators see these." />
      <TextAreaField label="Resolution" value={resolution} onChange={setResolution} maxLength={2000} help="Recorded when the issue is resolved." />
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

/** Complaints, support requests and disputes raised against one order or booking (existing backend ticket system). */
export function TicketsPanel({ state }: { state: AsyncState<Page<Ticket>> }) {
  const [open, setOpen] = useState<Ticket | null>(null)
  if (state.loading && !state.data) return <Spinner label="Loading tickets" />
  if (state.error && !state.data) return <ErrorState compact error={state.error} onRetry={state.reload} />
  const rows = state.data?.items ?? []
  if (rows.length === 0) return <EmptyState title="No complaints or disputes" message="Nothing has been raised against this record." />
  return (
    <>
      <ul className="list">
        {rows.map((t) => (
          <li key={t.id}>
            <span><strong>{t.ticket_number}</strong> · {humanize(t.type)}<br /><span className="muted small">{t.subject} · {dateTime(t.created_at)}</span></span>
            <span className="row-end"><StatusBadge status={t.status} /><Button size="sm" onClick={() => setOpen(t)}>Review</Button></span>
          </li>
        ))}
      </ul>
      {open && <Triage ticket={open} onClose={() => setOpen(null)} onSaved={state.reload} />}
    </>
  )
}
