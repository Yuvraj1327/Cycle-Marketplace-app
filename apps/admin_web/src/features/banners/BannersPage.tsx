import { useState } from 'react'
import { useAuth, useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, Modal, StatusBadge } from '../../components/common/ui'
import { CheckField, ImageField, SelectField, TextField } from '../../components/forms/fields'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { errorMessage } from '../../services/api/client'
import type { Banner } from '../../types/api'
import { dateTime, humanize } from '../../utils/format'
import { imagePath } from '../../utils/images'

type ActionType = Banner['action_type']
const ACTIONS: { value: ActionType; label: string }[] = [{ value: 'none', label: 'Does nothing' }, { value: 'product', label: 'Opens a product' }, { value: 'category', label: 'Opens a category' }, { value: 'service', label: 'Opens a service' }, { value: 'url', label: 'Opens a web link (https)' }]
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** datetime-local value (local time) <-> ISO */
const toLocal = (iso: string | null) => {
  if (!iso) return ''
  const d = new Date(iso)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`
}
const toIso = (local: string) => (local ? new Date(local).toISOString() : null)

function BannerForm({ initial, nextOrder, onClose, onSaved }: { initial: Banner | null; nextOrder: number; onClose: () => void; onSaved: () => void }) {
  const s = useServices()
  const { gateway } = useAuth()
  const toast = useToast()
  const [d, setD] = useState({ title: initial?.title ?? '', subtitle: initial?.subtitle ?? '', action_type: (initial?.action_type ?? 'none') as ActionType, action_value: initial?.action_value ?? '', sort_order: String(initial?.sort_order ?? nextOrder), is_active: initial?.is_active ?? true, starts_at: toLocal(initial?.starts_at ?? null), ends_at: toLocal(initial?.ends_at ?? null) })
  const [file, setFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [touched, setTouched] = useState(false)

  const e: Record<string, string> = {}
  if (!d.title.trim()) e.title = 'Enter a title.'
  else if (d.title.length > 120) e.title = 'At most 120 characters.'
  if (d.subtitle.length > 300) e.subtitle = 'At most 300 characters.'
  if (!initial && !file) e.image = 'Choose a banner image.'
  if (d.action_type === 'url' && !/^https:\/\/\S{3,500}$/.test(d.action_value)) e.action_value = 'Enter a link starting with https://'
  if (['product', 'category', 'service'].includes(d.action_type) && !UUID.test(d.action_value.trim())) e.action_value = `Enter the ${d.action_type}'s id (copy it from its page address).`
  if (!/^-?\d+$/.test(d.sort_order.trim())) e.sort_order = 'Enter a whole number.'
  if (d.starts_at && d.ends_at && new Date(d.ends_at) <= new Date(d.starts_at)) e.ends_at = 'The end must be after the start.'

  async function save() {
    setTouched(true)
    if (Object.keys(e).length) return
    setBusy(true)
    setError(null)
    try {
      const body = { title: d.title.trim(), subtitle: d.subtitle.trim() || null, action_type: d.action_type, action_value: d.action_type === 'none' ? null : d.action_value.trim(),
        sort_order: Number(d.sort_order), is_active: d.is_active, starts_at: toIso(d.starts_at), ends_at: toIso(d.ends_at), ...(file ? { image_path: '' } : {}) }
      if (file) {
        const path = imagePath('banners', file)
        await gateway.uploadImage('banners', path, file)
        body.image_path = path
      }
      if (initial) await s.banners.update(initial.id, body)
      else await s.banners.create({ ...body, image_path: body.image_path as string })
      toast.success(initial ? 'Banner saved.' : 'Banner created.')
      onSaved()
      onClose()
    } catch (err) {
      setError(errorMessage(err))
      setBusy(false)
    }
  }
  const show = (k: string) => (touched ? e[k] : null)

  return (
    <Modal title={initial ? 'Edit banner' : 'New banner'} wide onClose={busy ? () => undefined : onClose}
      footer={<><Button onClick={onClose} disabled={busy}>Cancel</Button><Button variant="primary" busy={busy} onClick={() => void save()}>Save</Button></>}>
      <TextField label="Title" required value={d.title} maxLength={120} onChange={(v) => setD({ ...d, title: v })} error={show('title')} />
      <TextField label="Description" value={d.subtitle} maxLength={300} onChange={(v) => setD({ ...d, subtitle: v })} error={show('subtitle')} help="Optional short line shown under the title." />
      <ImageField label="Banner image" required={!initial} file={file} onFile={setFile} currentUrl={initial?.image_url} help="Wide image recommended (JPEG, PNG or WebP, up to 5 MB)." />
      {show('image') && <p className="field-error" role="alert">{e.image}</p>}
      <div className="form-grid">
        <SelectField label="When tapped" value={d.action_type} onChange={(v) => setD({ ...d, action_type: v, action_value: '' })} options={ACTIONS} />
        {d.action_type !== 'none' && <TextField label={d.action_type === 'url' ? 'Link' : 'Record id'} required value={d.action_value} onChange={(v) => setD({ ...d, action_value: v })} error={show('action_value')} placeholder={d.action_type === 'url' ? 'https://…' : 'UUID'} />}
        <TextField label="Display order" inputMode="numeric" value={d.sort_order} onChange={(v) => setD({ ...d, sort_order: v })} error={show('sort_order')} help="Lower numbers are shown first." />
        <TextField label="Starts" type="datetime-local" value={d.starts_at} onChange={(v) => setD({ ...d, starts_at: v })} help="Optional. Empty = immediately." />
        <TextField label="Ends" type="datetime-local" value={d.ends_at} onChange={(v) => setD({ ...d, ends_at: v })} error={show('ends_at')} help="Optional. Empty = until removed." />
      </div>
      <CheckField label="Active" checked={d.is_active} onChange={(v) => setD({ ...d, is_active: v })} help="Customers see a banner only while it is active and inside its dates." />
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

/** Is the banner shown to customers right now? Derived from the same fields the backend filters on. */
function liveNow(b: Banner): boolean {
  const now = Date.now()
  return b.is_active && (!b.starts_at || new Date(b.starts_at).getTime() <= now) && (!b.ends_at || new Date(b.ends_at).getTime() > now)
}

export function BannersPage() {
  const s = useServices()
  const toast = useToast()
  const list = useAsync(() => s.banners.list(), [])
  const [editing, setEditing] = useState<Banner | 'new' | null>(null)
  const [preview, setPreview] = useState<Banner | null>(null)
  const [removing, setRemoving] = useState<Banner | null>(null)
  const [toggle, setToggle] = useState<Banner | null>(null)
  const [moving, setMoving] = useState(false)
  const rows = [...(list.data ?? [])].sort((a, b) => a.sort_order - b.sort_order || a.created_at.localeCompare(b.created_at))

  /** Swap display positions with the neighbour. Two backend updates; if the second fails the list is reloaded so the screen shows the truth. */
  async function move(i: number, dir: -1 | 1) {
    const a = rows[i], b = rows[i + dir]
    if (!a || !b) return
    setMoving(true)
    try {
      const [oa, ob] = a.sort_order === b.sort_order ? [i, i + dir] : [a.sort_order, b.sort_order]
      await s.banners.update(a.id, { sort_order: ob })
      await s.banners.update(b.id, { sort_order: oa })
      toast.success('Display order updated.')
    } catch (e) {
      toast.error(errorMessage(e))
    } finally {
      setMoving(false)
      list.reload()
    }
  }

  const columns: Column<Banner>[] = [
    { key: 'img', header: 'Banner', render: (b) => <img className="thumb" style={{ width: 96, height: 40 }} src={b.image_url} alt={`${b.title} banner`} /> },
    { key: 't', header: 'Title', render: (b) => <><strong>{b.title}</strong><div className="muted small">{b.subtitle ?? ''}</div></> },
    { key: 'a', header: 'Tap action', render: (b) => humanize(b.action_type) },
    { key: 'w', header: 'Schedule', render: (b) => <span className="small">{b.starts_at ? dateTime(b.starts_at) : 'Immediately'}<br />{b.ends_at ? `until ${dateTime(b.ends_at)}` : 'No end date'}</span> },
    { key: 'o', header: 'Order', align: 'right', render: (b) => b.sort_order },
    { key: 's', header: 'Status', render: (b) => <><StatusBadge status={b.is_active ? 'active' : 'inactive'} />{b.is_active && !liveNow(b) && <div className="muted small">Outside its dates</div>}</> },
    { key: 'x', header: 'Actions', align: 'right', render: (b) => {
      const i = rows.findIndex((r) => r.id === b.id)
      return (
        <span className="row-actions">
          <Button size="sm" aria-label={`Move ${b.title} up`} disabled={i === 0 || moving} onClick={() => void move(i, -1)}>↑</Button>
          <Button size="sm" aria-label={`Move ${b.title} down`} disabled={i === rows.length - 1 || moving} onClick={() => void move(i, 1)}>↓</Button>
          <Button size="sm" onClick={() => setPreview(b)}>Preview</Button>
          <Button size="sm" onClick={() => setEditing(b)}>Edit</Button>
          <Button size="sm" onClick={() => setToggle(b)}>{b.is_active ? 'Deactivate' : 'Activate'}</Button>
          <Button size="sm" onClick={() => setRemoving(b)}>Remove</Button>
        </span>
      )
    } },
  ]

  return (
    <>
      <PageHeader title="Promotional banners" subtitle="Banners shown at the top of the customer app." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Promotional banners' }]}
        actions={<Button variant="primary" onClick={() => setEditing('new')}>New banner</Button>} />
      <Card>
        <DataTable caption="Banners" columns={columns} rows={list.data ? rows : null} rowKey={(b) => b.id} loading={list.loading} error={list.error} onRetry={list.reload}
          emptyTitle="No banners" emptyMessage="Create a banner to promote offers in the customer app." />
      </Card>
      {editing && <BannerForm initial={editing === 'new' ? null : editing} nextOrder={rows.length ? Math.max(...rows.map((r) => r.sort_order)) + 1 : 0} onClose={() => setEditing(null)} onSaved={list.reload} />}
      {preview && (
        <Modal title={`Preview: ${preview.title}`} wide onClose={() => setPreview(null)} footer={<Button onClick={() => setPreview(null)}>Close</Button>}>
          <img className="banner-prev" src={preview.image_url} alt={`${preview.title} banner preview`} />
          <h3 className="section-gap">{preview.title}</h3>
          {preview.subtitle && <p>{preview.subtitle}</p>}
          <p className="muted small">{liveNow(preview) ? 'Customers can see this banner now.' : 'Customers cannot see this banner right now (inactive or outside its dates).'}</p>
        </Modal>
      )}
      {toggle && (
        <ConfirmDialog title={toggle.is_active ? 'Deactivate this banner?' : 'Activate this banner?'} confirmLabel={toggle.is_active ? 'Deactivate' : 'Activate'} danger={toggle.is_active}
          message={toggle.is_active ? 'Customers will stop seeing it.' : 'Customers can see it again (inside its dates).'}
          onConfirm={async () => { await s.banners.update(toggle.id, { is_active: !toggle.is_active }); toast.success(toggle.is_active ? 'Banner deactivated.' : 'Banner activated.'); list.reload() }} onClose={() => setToggle(null)} />
      )}
      {removing && (
        <ConfirmDialog title={`Remove “${removing.title}”?`} confirmLabel="Remove" danger message="The banner is deleted. The image file stays in storage."
          onConfirm={async () => { await s.banners.remove(removing.id); toast.success('Banner removed.'); list.reload() }} onClose={() => setRemoving(null)} />
      )}
    </>
  )
}
