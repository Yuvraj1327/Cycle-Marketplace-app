import { useState } from 'react'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, Modal, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { CheckField, SelectField, TextAreaField, TextField } from '../../components/forms/fields'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import { errorMessage } from '../../services/api/client'
import type { Coupon, CouponInput } from '../../types/api'
import { dateTime, money } from '../../utils/format'

const LIMIT = 20
const pad = (n: number) => String(n).padStart(2, '0')
const toLocal = (iso: string | null) => { if (!iso) return ''; const d = new Date(iso); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}` }
const discount = (c: Pick<Coupon, 'discount_type' | 'discount_value' | 'max_discount_amount'>) => (c.discount_type === 'percentage' ? `${c.discount_value}% off${c.max_discount_amount != null ? ` (max ${money(c.max_discount_amount)})` : ''}` : `${money(c.discount_value)} off`)

function CouponForm({ initial, onClose, onSaved }: { initial: Coupon | null; onClose: () => void; onSaved: () => void }) {
  const s = useServices()
  const toast = useToast()
  const used = (initial?.used_count ?? 0) > 0
  const [d, setD] = useState({ code: initial?.code ?? '', description: initial?.description ?? '', type: (initial?.discount_type ?? 'percentage') as 'percentage' | 'fixed', value: initial ? String(initial.discount_value) : '',
    max: initial?.max_discount_amount != null ? String(initial.max_discount_amount) : '', min: String(initial?.min_order_amount ?? 0), from: toLocal(initial?.valid_from ?? null), until: toLocal(initial?.valid_until ?? null),
    usage: initial?.usage_limit != null ? String(initial.usage_limit) : '', perUser: initial?.per_user_limit != null ? String(initial.per_user_limit) : '', active: initial?.is_active ?? true })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [touched, setTouched] = useState(false)
  const money2 = (t: string) => /^\d+(\.\d{1,2})?$/.test(t.trim())
  const int = (t: string) => /^[1-9]\d*$/.test(t.trim())
  const v = Number(d.value)
  const e: Record<string, string> = {}
  if (!/^[A-Za-z0-9_-]{3,30}$/.test(d.code.trim())) e.code = 'Use 3–30 letters, numbers, - or _ (no spaces).'
  if (!money2(d.value) || v <= 0) e.value = 'Enter a discount greater than zero.'
  else if (d.type === 'percentage' && v > 100) e.value = 'A percentage cannot exceed 100.'
  if (d.type === 'percentage' && d.max.trim() && !money2(d.max)) e.max = 'Enter an amount, or leave empty for no cap.'
  if (!money2(d.min)) e.min = 'Enter 0 or more.'
  if (d.from && d.until && new Date(d.until) <= new Date(d.from)) e.until = 'The end must be after the start.'
  if (d.usage.trim() && !int(d.usage)) e.usage = 'Enter a whole number above zero, or leave empty.'
  else if (d.usage.trim() && Number(d.usage) < (initial?.used_count ?? 0)) e.usage = `Already redeemed ${initial?.used_count} time(s); the limit cannot be lower.`
  if (d.perUser.trim() && !int(d.perUser)) e.perUser = 'Enter a whole number above zero, or leave empty.'

  async function save() {
    setTouched(true)
    if (Object.keys(e).length) return
    setBusy(true)
    setError(null)
    try {
      const body: CouponInput = { description: d.description.trim() || null, discount_type: d.type, discount_value: v, max_discount_amount: d.type === 'percentage' && d.max.trim() ? Number(d.max) : null, min_order_amount: Number(d.min),
        applies_to: 'products', valid_until: d.until ? new Date(d.until).toISOString() : null, usage_limit: d.usage.trim() ? Number(d.usage) : null, per_user_limit: d.perUser.trim() ? Number(d.perUser) : null, is_active: d.active }
      if (d.from) body.valid_from = new Date(d.from).toISOString()
      if (initial) {
        if (d.code.trim().toUpperCase() !== initial.code) body.code = d.code.trim()
        await s.coupons.update(initial.id, body)
      } else {
        const { max_discount_amount, description, valid_until, usage_limit, per_user_limit, ...rest } = body
        await s.coupons.create({ ...rest, code: d.code.trim(), ...(max_discount_amount != null ? { max_discount_amount } : {}), ...(description ? { description } : {}), ...(valid_until ? { valid_until } : {}), ...(usage_limit != null ? { usage_limit } : {}), ...(per_user_limit != null ? { per_user_limit } : {}) })
      }
      toast.success(initial ? 'Coupon saved.' : 'Coupon created.')
      onSaved()
      onClose()
    } catch (err) {
      setError(errorMessage(err))
      setBusy(false)
    }
  }
  const sh = (k: string) => (touched ? e[k] : null)
  return (
    <Modal title={initial ? `Edit ${initial.code}` : 'New coupon'} wide onClose={busy ? () => undefined : onClose} footer={<><Button onClick={onClose} disabled={busy}>Cancel</Button><Button variant="primary" busy={busy} onClick={() => void save()}>Save</Button></>}>
      <div className="form-grid">
        <TextField label="Coupon code" required value={d.code} maxLength={30} disabled={used} onChange={(x) => setD({ ...d, code: x })} error={sh('code')} help={used ? 'Already used, so the code can no longer change.' : 'Customers type this at checkout. Not case-sensitive.'} />
        <SelectField label="Discount type" value={d.type} onChange={(x) => setD({ ...d, type: x })} options={[{ value: 'percentage', label: 'Percentage of the order' }, { value: 'fixed', label: 'Fixed amount off' }]} />
        <TextField label={d.type === 'percentage' ? 'Percentage (%)' : 'Amount off (₹)'} required inputMode="decimal" value={d.value} onChange={(x) => setD({ ...d, value: x })} error={sh('value')} />
        {d.type === 'percentage' && <TextField label="Maximum discount (₹)" inputMode="decimal" value={d.max} onChange={(x) => setD({ ...d, max: x })} error={sh('max')} help="Optional cap." />}
        <TextField label="Minimum order (₹)" required inputMode="decimal" value={d.min} onChange={(x) => setD({ ...d, min: x })} error={sh('min')} />
        <TextField label="Valid from" type="datetime-local" value={d.from} onChange={(x) => setD({ ...d, from: x })} help="Empty = now." />
        <TextField label="Valid until" type="datetime-local" value={d.until} onChange={(x) => setD({ ...d, until: x })} error={sh('until')} help="Empty = no end date." />
        <TextField label="Total redemptions allowed" inputMode="numeric" value={d.usage} onChange={(x) => setD({ ...d, usage: x })} error={sh('usage')} help="Optional. Empty = unlimited." />
        <TextField label="Per customer limit" inputMode="numeric" value={d.perUser} onChange={(x) => setD({ ...d, perUser: x })} error={sh('perUser')} help="Optional. Empty = unlimited." />
      </div>
      <TextAreaField label="Description" value={d.description} onChange={(x) => setD({ ...d, description: x })} maxLength={300} help="Internal note, not shown to customers." />
      <CheckField label="Active" checked={d.active} onChange={(x) => setD({ ...d, active: x })} />
      <p className="muted small">Applies to product checkout. Service bookings take no payment yet, so coupons are not used for services.</p>
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

export function CouponsPage() {
  const s = useServices()
  const toast = useToast()
  const { values, page, set, setPage } = useListQuery(['q', 'is_active'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const list = useAsync(() => s.coupons.list({ q: values.q, is_active: values.is_active, page, limit: LIMIT }), [values.q, values.is_active, page])
  const [editing, setEditing] = useState<Coupon | 'new' | null>(null)
  const [toggle, setToggle] = useState<Coupon | null>(null)

  const columns: Column<Coupon>[] = [
    { key: 'c', header: 'Code', render: (c) => <><strong>{c.code}</strong><div className="muted small">{c.description ?? ''}</div></> },
    { key: 'd', header: 'Discount', render: (c) => discount(c) },
    { key: 'm', header: 'Minimum order', align: 'right', render: (c) => money(c.min_order_amount) },
    { key: 'v', header: 'Valid', render: (c) => <span className="small">{dateTime(c.valid_from)}<br />{c.valid_until ? `until ${dateTime(c.valid_until)}` : 'no end date'}</span> },
    { key: 'u', header: 'Used', render: (c) => <>{c.used_count}{c.usage_limit != null ? ` / ${c.usage_limit}` : ''}<div className="muted small">{c.per_user_limit != null ? `${c.per_user_limit} per customer` : 'no per-customer limit'}</div></> },
    { key: 's', header: 'Status', render: (c) => <StatusBadge status={c.state} /> },
    { key: 'a', header: '', align: 'right', render: (c) => <span className="row-actions"><Button size="sm" onClick={() => setEditing(c)}>Edit</Button><Button size="sm" onClick={() => setToggle(c)}>{c.is_active ? 'Deactivate' : 'Activate'}</Button></span> },
  ]

  return (
    <>
      <PageHeader title="Offers and coupons" subtitle="Discount codes customers can use at checkout." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Settings', to: '/settings' }, { label: 'Coupons' }]} actions={<Button variant="primary" onClick={() => setEditing('new')}>New coupon</Button>} />
      <p className="note">The platform counts how many times each coupon was redeemed; it does not keep a separate list of redemptions. Coupons are deactivated rather than deleted so past orders keep the code they used.</p>
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search code or description" />
          <SelectFilter label="Active" value={values.is_active} onChange={(v) => set({ is_active: v })} options={[{ value: '', label: 'All' }, { value: 'true', label: 'Active' }, { value: 'false', label: 'Inactive' }]} />
        </div>
        <DataTable caption="Coupons" columns={columns} rows={list.data?.items ?? null} rowKey={(c) => c.id} loading={list.loading} error={list.error} onRetry={list.reload} emptyTitle="No coupons yet" emptyMessage="Create the first coupon." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
      {editing && <CouponForm initial={editing === 'new' ? null : editing} onClose={() => setEditing(null)} onSaved={list.reload} />}
      {toggle && (
        <ConfirmDialog title={toggle.is_active ? `Deactivate ${toggle.code}?` : `Activate ${toggle.code}?`} confirmLabel={toggle.is_active ? 'Deactivate' : 'Activate'} danger={toggle.is_active}
          message={toggle.is_active ? 'Customers can no longer use this code. Past orders are not changed.' : 'Customers can use this code again (inside its dates and limits).'}
          onConfirm={async () => { await s.coupons.update(toggle.id, { is_active: !toggle.is_active }); toast.success(toggle.is_active ? 'Coupon deactivated.' : 'Coupon activated.'); list.reload() }} onClose={() => setToggle(null)} />
      )}
    </>
  )
}
