import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, Pagination, SelectFilter, StatusBadge } from '../../components/common/ui'
import { SelectField, TextAreaField, TextField } from '../../components/forms/fields'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useDebounce } from '../../hooks/useDebounce'
import { useListQuery } from '../../hooks/useListQuery'
import type { Announcement, AnnouncementType, Audience } from '../../types/api'
import { dateTime, humanize } from '../../utils/format'

const LIMIT = 10
const TYPE_OPTIONS: { value: AnnouncementType; label: string }[] = [{ value: 'promotion', label: 'Offer / promotion' }, { value: 'announcement', label: 'Announcement' }, { value: 'system', label: 'Operational / system update' }]
const AUDIENCES: { value: Audience; label: string }[] = [{ value: 'customers', label: 'All active customers' }, { value: 'vendors', label: 'All active vendors' }, { value: 'specific', label: 'Specific people' }]

interface Person { id: string; name: string; role: 'Customer' | 'Vendor'; detail: string }

/** Finds customers and vendors by name / e-mail / phone. Only active-account profile ids can be targeted; the backend re-validates every id. */
function RecipientPicker({ chosen, onChange }: { chosen: Person[]; onChange: (p: Person[]) => void }) {
  const s = useServices()
  const [text, setText] = useState('')
  const q = useDebounce(text.trim())
  const found = useAsync(async (): Promise<Person[]> => {
    if (q.length < 2) return []
    const [c, v] = await Promise.all([s.customers.list({ q, limit: 5 }), s.vendors.list({ q, limit: 5 })])
    return [
      ...c.items.map((x) => ({ id: x.id, name: x.full_name ?? 'Customer', role: 'Customer' as const, detail: x.email ?? x.phone ?? '' })),
      ...v.items.map((x) => ({ id: x.user_id, name: x.business_name, role: 'Vendor' as const, detail: x.owner_email ?? x.contact_phone })),
    ]
  }, [q])
  const add = (p: Person) => !chosen.some((c) => c.id === p.id) && chosen.length < 200 && onChange([...chosen, p])
  return (
    <div className="field">
      <label htmlFor="recipient-search">Recipients <span aria-hidden="true">*</span></label>
      {chosen.length > 0 && <div className="chips">{chosen.map((p) => <span className="chip" key={p.id}>{p.name} ({p.role})<button type="button" aria-label={`Remove ${p.name}`} onClick={() => onChange(chosen.filter((c) => c.id !== p.id))}>×</button></span>)}</div>}
      <input id="recipient-search" type="search" value={text} onChange={(e) => setText(e.target.value)} placeholder="Search a customer or vendor by name, e-mail or phone" maxLength={100} />
      {q.length >= 2 && (
        <ul className="list" aria-label="Matching people">
          {found.loading && <li className="muted">Searching…</li>}
          {!found.loading && (found.data ?? []).length === 0 && <li className="muted">No match.</li>}
          {(found.data ?? []).map((p) => <li key={`${p.role}-${p.id}`}><span>{p.name} <span className="muted small">{p.role} · {p.detail}</span></span><Button size="sm" disabled={chosen.some((c) => c.id === p.id)} onClick={() => add(p)}>Add</Button></li>)}
        </ul>
      )}
    </div>
  )
}

function Composer({ onSent }: { onSent: () => void }) {
  const s = useServices()
  const toast = useToast()
  const [title, setTitle] = useState('')
  const [message, setMessage] = useState('')
  const [type, setType] = useState<AnnouncementType>('announcement')
  const [audience, setAudience] = useState<Audience>('customers')
  const [people, setPeople] = useState<Person[]>([])
  const [touched, setTouched] = useState(false)
  const [confirm, setConfirm] = useState(false)

  const e: Record<string, string> = {}
  if (title.trim().length < 3) e.title = 'Enter a title of at least 3 characters.'
  if (message.trim().length < 3) e.message = 'Enter a message of at least 3 characters.'
  if (audience === 'specific' && people.length === 0) e.people = 'Choose at least one recipient.'
  const who = audience === 'specific' ? `${people.length} selected ${people.length === 1 ? 'person' : 'people'}` : audience === 'customers' ? 'every active customer' : 'every active vendor'

  async function send() {
    const out = await s.communication.send({ title: title.trim(), message: message.trim(), type, audience, ...(audience === 'specific' ? { user_ids: people.map((p) => p.id) } : {}) })
    toast.success(`Sent to ${out.recipient_count} ${out.recipient_count === 1 ? 'recipient' : 'recipients'} as an in-app notification.`)
    setTitle(''); setMessage(''); setPeople([]); setTouched(false)
    onSent()
  }

  return (
    <Card title="New announcement">
      <div className="form-grid">
        <SelectField label="Type" value={type} onChange={setType} options={TYPE_OPTIONS} />
        <SelectField label="Audience" value={audience} onChange={(v) => { setAudience(v); setPeople([]) }} options={AUDIENCES} />
      </div>
      {audience === 'specific' && <><RecipientPicker chosen={people} onChange={setPeople} />{touched && e.people && <p className="field-error" role="alert">{e.people}</p>}</>}
      <TextField label="Title" required value={title} maxLength={150} onChange={setTitle} error={touched ? e.title : null} />
      <TextAreaField label="Message" required value={message} maxLength={2000} onChange={setMessage} error={touched ? e.message : null} help="Plain text, up to 2000 characters." />
      <p className="muted small">Creates an in-app notification for each recipient with an active account, then sends a push message to their registered devices when push is configured on the server.</p>
      <Button variant="primary" onClick={() => { setTouched(true); if (Object.keys(e).length === 0) setConfirm(true) }}>Review and send</Button>
      {confirm && (
        <ConfirmDialog title="Send this announcement?" confirmLabel="Send" message={<>“<strong>{title.trim()}</strong>” will be sent to {who} ({humanize(type)}). It cannot be recalled once sent.</>}
          onConfirm={send} onClose={() => setConfirm(false)} />
      )}
    </Card>
  )
}

export function AnnouncementsPage() {
  const s = useServices()
  const { values, page, set, setPage } = useListQuery(['type', 'audience'] as const)
  const list = useAsync(() => s.communication.announcements({ type: values.type, audience: values.audience, page, limit: LIMIT }), [values.type, values.audience, page])

  const columns: Column<Announcement>[] = [
    { key: 't', header: 'Announcement', render: (a) => <><strong>{a.title}</strong><div className="muted small">{a.message.length > 90 ? `${a.message.slice(0, 90)}…` : a.message}</div></> },
    { key: 'ty', header: 'Type', render: (a) => <StatusBadge status={a.type} label={humanize(a.type)} /> },
    { key: 'au', header: 'Audience', render: (a) => humanize(a.audience) },
    { key: 'r', header: 'Recipients', align: 'right', render: (a) => a.recipient_count },
    { key: 'dl', header: 'In-app delivered', align: 'right', render: (a) => a.delivered },
    { key: 'ps', header: 'Push sent', align: 'right', render: (a) => <span title="Devices reached. Recipients without a registered device are not counted as failures.">{a.push_sent}{a.push_pending > 0 ? <span className="muted small"> (+{a.push_pending} waiting)</span> : null}{a.push_failed > 0 ? <span className="muted small"> ({a.push_failed} failed)</span> : null}</span> },
    { key: 'rd', header: 'Read', align: 'right', render: (a) => a.read },
    { key: 'by', header: 'Sent by', render: (a) => a.created_by_name ?? '—' },
    { key: 'd', header: 'Sent', render: (a) => dateTime(a.created_at) },
    { key: 'l', header: '', render: (a) => <Link to={`/notifications?announcement_id=${a.id}`}>Recipients</Link> },
  ]

  return (
    <>
      <PageHeader title="Announcements" subtitle="Broadcast offers, new products and platform updates to customers and vendors." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Announcements' }]} />
      <Composer onSent={list.reload} />
      <Card title="Announcement history">
        <div className="toolbar">
          <SelectFilter label="Type" value={values.type} onChange={(v) => set({ type: v })} options={[{ value: '', label: 'All' }, ...TYPE_OPTIONS]} />
          <SelectFilter label="Audience" value={values.audience} onChange={(v) => set({ audience: v })} options={[{ value: '', label: 'All' }, ...AUDIENCES]} />
        </div>
        <DataTable caption="Announcements" columns={columns} rows={list.data?.items ?? null} rowKey={(a) => a.id} loading={list.loading} error={list.error} onRetry={list.reload} emptyTitle="No announcements yet" emptyMessage="Compose the first one above." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
