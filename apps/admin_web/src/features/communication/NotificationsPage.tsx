import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ErrorState, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { DateRange } from '../../components/common/filters'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import type { NotificationRecord } from '../../types/api'
import { errorMessage } from '../../services/api/client'
import { dateTime, humanize } from '../../utils/format'

const LIMIT = 20
const PUSH_LABEL: Record<string, string> = { pending: 'Push waiting', sending: 'Push sending', sent: 'Push sent', failed: 'Push failed', skipped: 'No push', expired: 'Push expired' }

/** Is push configured on the server, how many devices are registered, and what happened to recent pushes. Never shows a token or credential. */
function PushCard() {
  const s = useServices()
  const toast = useToast()
  const st = useAsync(() => s.communication.pushStatus(), [])
  const [busy, setBusy] = useState(false)
  async function sendNow() {
    setBusy(true)
    try {
      const r = await s.communication.dispatchPush()
      toast.success(r.configured ? `Push cycle done: ${r.sent} sent, ${r.retry} to retry, ${r.failed} failed, ${r.skipped} skipped.` : 'Push is not configured on the server, so nothing was sent.')
      st.reload()
    } catch (e) {
      toast.error(errorMessage(e))
    } finally {
      setBusy(false)
    }
  }
  if (st.error && !st.data) return <ErrorState compact error={st.error} onRetry={st.reload} />
  const d = st.data
  if (!d) return null
  const by = d.by_status ?? {}
  const dev = d.active_devices ?? {}
  const n = (k: string) => by[k] ?? 0
  return (
    <Card title="Push delivery" actions={<Button size="sm" busy={busy} onClick={() => void sendNow()}>Send pending now</Button>}>
      {d.configured
        ? <p>Push provider <strong>{d.provider}</strong> is configured{d.dispatcher_enabled ? ' and the background sender is running' : '; the background sender is off, use “Send pending now”'}.</p>
        : <p className="note">Push is <strong>not configured</strong> on the server (no Firebase credentials). Notifications still appear inside the apps; nothing is sent to phones until the server has the Firebase service account.</p>}
      <p className="small">Devices registered — customers: <strong>{dev.customer ?? 0}</strong>, vendors: <strong>{dev.vendor ?? 0}</strong>. Last 7 days — sent: <strong>{n('sent')}</strong>, waiting: <strong>{n('pending') + n('sending')}</strong>, failed: <strong>{n('failed')}</strong>, expired: {n('expired')}, no device / inactive: {n('skipped')}.</p>
      {(d.recent_failures ?? []).length > 0 && <ul className="list">{(d.recent_failures ?? []).map((f) => <li key={f.id}><span>{f.title}<br /><span className="muted small">{f.push_error ?? 'failed'} · {f.push_attempts} attempts · {dateTime(f.created_at)}</span></span></li>)}</ul>}
    </Card>
  )
}
const TYPES = [{ value: '', label: 'All types' }, ...['order', 'payment', 'service_booking', 'pickup_delivery', 'promotion', 'announcement', 'system'].map((v) => ({ value: v, label: humanize(v) }))]

export function NotificationsPage() {
  const s = useServices()
  const { values, page, set, setPage } = useListQuery(['q', 'type', 'announcement_id', 'date_from', 'date_to'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const list = useAsync(() => s.communication.records({ q: values.q, type: values.type, announcement_id: values.announcement_id, date_from: values.date_from, date_to: values.date_to, page, limit: LIMIT }),
    [values.q, values.type, values.announcement_id, values.date_from, values.date_to, page])

  const columns: Column<NotificationRecord>[] = [
    { key: 'r', header: 'Recipient', render: (n) => <>{n.recipient_name ?? '—'}<div className="muted small">{n.recipient_role ? humanize(n.recipient_role) : ''}</div></> },
    { key: 't', header: 'Type', render: (n) => <StatusBadge status={n.type} label={humanize(n.type)} /> },
    { key: 'm', header: 'Notification', render: (n) => <><strong>{n.title}</strong><div className="muted small">{n.message.length > 110 ? `${n.message.slice(0, 110)}…` : n.message}</div></> },
    { key: 'rel', header: 'About', render: (n) => (n.related_type ? humanize(n.related_type) : n.announcement_id ? 'Announcement' : '—') },
    { key: 'rd', header: 'Read', render: (n) => (n.is_read ? 'Read' : <span className="muted">Unread</span>) },
    { key: 'ch', header: 'Delivery', render: (n) => <>In-app<div className="muted small" title={n.push_error ?? undefined}>{PUSH_LABEL[n.push_status] ?? n.push_status}</div></> },
    { key: 'd', header: 'Created', render: (n) => dateTime(n.created_at) },
  ]

  return (
    <>
      <PageHeader title="Notifications" subtitle="Every in-app notification the platform has created: orders, payments, bookings, offers and announcements." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Notifications' }]}
        actions={<><Link className="btn btn-primary btn-md" to="/announcements">New announcement</Link><Button onClick={list.reload}>Refresh</Button></>} />
      <PushCard />
      <p className="note">“In-app” means the notification exists in the recipient's notification list. “Push sent” means the push provider accepted the message for at least one registered device; it does not prove the phone displayed it.</p>
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search recipient name, e-mail or phone" />
          <SelectFilter label="Type" value={values.type} onChange={(v) => set({ type: v })} options={TYPES} />
          <DateRange from={values.date_from} to={values.date_to} onChange={(r) => set({ date_from: r.from, date_to: r.to })} />
        </div>
        {values.announcement_id && <p className="small">Showing one announcement's recipients. <button type="button" className="btn btn-ghost btn-sm" onClick={() => set({ announcement_id: '' })}>Show all</button></p>}
        <DataTable caption="Notification records" columns={columns} rows={list.data?.items ?? null} rowKey={(n) => n.id} loading={list.loading} error={list.error} onRetry={list.reload} emptyTitle="No notifications found" emptyMessage="Try changing the search or filters." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
