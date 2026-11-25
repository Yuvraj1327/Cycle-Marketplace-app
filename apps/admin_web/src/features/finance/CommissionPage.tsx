import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, MetricCard, Modal, StatusBadge } from '../../components/common/ui'
import { CheckField, SelectField, TextField } from '../../components/forms/fields'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { errorMessage } from '../../services/api/client'
import type { CommissionRule, CommissionRuleInput } from '../../types/api'
import { dateOnly, humanize, isoDay, money } from '../../utils/format'
import { AuditTrail } from '../common/AuditTrail'
import { KIND_LABELS } from '../../utils/options'

const SCOPE_LABEL: Record<CommissionRule['scope'], string> = { global: 'Every vendor and category', vendor: 'One vendor', category: 'One category', vendor_and_category: 'One vendor in one category', service_category: 'One service category' }
const pad = (n: number) => String(n).padStart(2, '0')
const toLocal = (iso: string | null) => { if (!iso) return ''; const d = new Date(iso); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}` }
const rate = (r: Pick<CommissionRule, 'commission_type' | 'commission_value'>) => (r.commission_type === 'percentage' ? `${r.commission_value}%` : `${money(r.commission_value)} per unit`)

function RuleForm({ initial, onClose, onSaved }: { initial: CommissionRule | null; onClose: () => void; onSaved: () => void }) {
  const s = useServices()
  const toast = useToast()
  const vendors = useAsync(() => s.vendors.list({ verification_status: 'approved', limit: 100 }), [])
  const cats = useAsync(() => s.categories.list(), [])
  const scats = useAsync(() => s.serviceCategories.list(), [])
  const [d, setD] = useState({ name: initial?.name ?? '', applies_to: (initial?.applies_to ?? 'product') as 'product' | 'service', vendor_id: initial?.vendor_id ?? '', category_id: initial?.category_id ?? '', service_category_id: initial?.service_category_id ?? '',
    commission_type: (initial?.commission_type ?? 'percentage') as 'percentage' | 'fixed', commission_value: initial ? String(initial.commission_value) : '', priority: String(initial?.priority ?? 0), is_active: initial?.is_active ?? true,
    effective_from: toLocal(initial?.effective_from ?? null), effective_until: toLocal(initial?.effective_until ?? null) })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [touched, setTouched] = useState(false)
  const v = Number(d.commission_value)
  const e: Record<string, string> = {}
  if (d.name.trim().length < 2) e.name = 'Enter a name of at least 2 characters.'
  if (!d.commission_value.trim() || Number.isNaN(v) || v < 0) e.commission_value = 'Enter a value of 0 or more.'
  else if (d.commission_type === 'percentage' && v > 100) e.commission_value = 'A percentage cannot exceed 100.'
  else if (!/^\d+(\.\d{1,2})?$/.test(d.commission_value.trim())) e.commission_value = 'Use at most two decimals.'
  if (!/^-?\d+$/.test(d.priority.trim())) e.priority = 'Enter a whole number.'
  if (d.effective_from && d.effective_until && new Date(d.effective_until) <= new Date(d.effective_from)) e.effective_until = 'The end must be after the start.'

  async function save() {
    setTouched(true)
    if (Object.keys(e).length) return
    setBusy(true)
    setError(null)
    try {
      const until = d.effective_until ? new Date(d.effective_until).toISOString() : null
      if (initial) {
        await s.commission.update(initial.id, { name: d.name.trim(), commission_type: d.commission_type, commission_value: v, priority: Number(d.priority), is_active: d.is_active, effective_until: until })
      } else {
        const body: CommissionRuleInput = { name: d.name.trim(), applies_to: d.applies_to, commission_type: d.commission_type, commission_value: v, priority: Number(d.priority), is_active: d.is_active }
        if (d.applies_to === 'product') { if (d.vendor_id) body.vendor_id = d.vendor_id; if (d.category_id) body.category_id = d.category_id } else if (d.service_category_id) body.service_category_id = d.service_category_id
        if (d.effective_from) body.effective_from = new Date(d.effective_from).toISOString()
        if (until) body.effective_until = until
        await s.commission.create(body)
      }
      toast.success(initial ? 'Commission rule saved.' : 'Commission rule created.')
      onSaved()
      onClose()
    } catch (err) {
      setError(errorMessage(err))
      setBusy(false)
    }
  }
  const sh = (k: string) => (touched ? e[k] : null)
  return (
    <Modal title={initial ? `Edit ${initial.name}` : 'New commission rule'} wide onClose={busy ? () => undefined : onClose} footer={<><Button onClick={onClose} disabled={busy}>Cancel</Button><Button variant="primary" busy={busy} onClick={() => void save()}>Save</Button></>}>
      {initial && <p className="note">Orders already placed keep the commission they were charged. A change only affects orders placed from now on. Which products or vendors a rule covers cannot be changed: create a new rule instead.</p>}
      <TextField label="Rule name" required value={d.name} onChange={(x) => setD({ ...d, name: x })} error={sh('name')} maxLength={120} />
      <div className="form-grid">
        <SelectField label="Applies to" value={d.applies_to} disabled={!!initial} onChange={(x) => setD({ ...d, applies_to: x, category_id: '', service_category_id: '' })}
          options={[{ value: 'product', label: 'Product sales' }, { value: 'service', label: 'Services (recorded only)' }]} help={d.applies_to === 'service' ? 'Service payments are not collected through the platform yet, so a service rule is stored but not applied to any charge.' : undefined} />
        <SelectField label="Calculation" value={d.commission_type} onChange={(x) => setD({ ...d, commission_type: x })} options={[{ value: 'percentage', label: 'Percentage of item value' }, { value: 'fixed', label: 'Fixed amount per unit' }]} />
        {d.applies_to === 'product' && !initial && <>
          <SelectField label="Vendor (optional)" value={d.vendor_id} onChange={(x) => setD({ ...d, vendor_id: x })} options={[{ value: '', label: 'Every vendor' }, ...(vendors.data?.items ?? []).map((x) => ({ value: x.id, label: x.business_name }))]} />
          <SelectField label="Category (optional)" value={d.category_id} onChange={(x) => setD({ ...d, category_id: x })} options={[{ value: '', label: 'Every category' }, ...(cats.data ?? []).map((x) => ({ value: x.id, label: `${x.name} (${KIND_LABELS[x.kind] ?? x.kind})` }))]} />
        </>}
        {d.applies_to === 'service' && !initial && <SelectField label="Service category (optional)" value={d.service_category_id} onChange={(x) => setD({ ...d, service_category_id: x })} options={[{ value: '', label: 'Every service category' }, ...(scats.data ?? []).map((x) => ({ value: x.id, label: x.name }))]} />}
        <TextField label={d.commission_type === 'percentage' ? 'Percentage (%)' : 'Amount per unit (₹)'} required inputMode="decimal" value={d.commission_value} onChange={(x) => setD({ ...d, commission_value: x })} error={sh('commission_value')} />
        <TextField label="Priority" inputMode="numeric" value={d.priority} onChange={(x) => setD({ ...d, priority: x })} error={sh('priority')} help="When two rules cover the same sale, the more specific rule wins, then the higher priority." />
        {!initial && <TextField label="Effective from" type="datetime-local" value={d.effective_from} onChange={(x) => setD({ ...d, effective_from: x })} help="Empty = now." />}
        <TextField label="Effective until" type="datetime-local" value={d.effective_until} onChange={(x) => setD({ ...d, effective_until: x })} error={sh('effective_until')} help="Empty = no end date." />
      </div>
      <CheckField label="Active" checked={d.is_active} onChange={(x) => setD({ ...d, is_active: x })} />
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

function Resolver() {
  const s = useServices()
  const vendors = useAsync(() => s.vendors.list({ verification_status: 'approved', limit: 100 }), [])
  const cats = useAsync(() => s.categories.list(), [])
  const [vendor, setVendor] = useState('')
  const [cat, setCat] = useState('')
  const [out, setOut] = useState<{ rule: CommissionRule | null; note: string | null } | null>(null)
  const [error, setError] = useState<string | null>(null)
  async function check() {
    setError(null)
    try { setOut(await s.commission.resolve(vendor || undefined, cat || undefined)) } catch (e) { setError(errorMessage(e)) }
  }
  return (
    <Card title="Which rule applies?" actions={<Button size="sm" onClick={() => void check()}>Check</Button>}>
      <div className="form-grid">
        <SelectField label="Vendor" value={vendor} onChange={setVendor} options={[{ value: '', label: 'Any vendor' }, ...(vendors.data?.items ?? []).map((x) => ({ value: x.id, label: x.business_name }))]} />
        <SelectField label="Product category" value={cat} onChange={setCat} options={[{ value: '', label: 'Any category' }, ...(cats.data ?? []).map((x) => ({ value: x.id, label: x.name }))]} />
      </div>
      {error && <p className="form-error" role="alert">{error}</p>}
      {out && (out.rule ? <p role="status">Checkout would apply <strong>{out.rule.name}</strong>: {rate(out.rule)} ({SCOPE_LABEL[out.rule.scope]}, priority {out.rule.priority}).</p> : <p className="note" role="status">{out.note}</p>)}
    </Card>
  )
}

export function CommissionPage() {
  const s = useServices()
  const toast = useToast()
  const rules = useAsync(() => s.commission.list(), [])
  const history = useAsync(() => s.commission.history(), [])
  const summary = useAsync(() => { const to = new Date(); const from = new Date(); from.setDate(to.getDate() - 29); return s.payments.summary(`${isoDay(from)}T00:00:00+05:30`, `${isoDay(to)}T23:59:59+05:30`) }, [])
  const [editing, setEditing] = useState<CommissionRule | 'new' | null>(null)
  const [toggle, setToggle] = useState<CommissionRule | null>(null)
  const refresh = () => { rules.reload(); history.reload() }

  const columns: Column<CommissionRule>[] = [
    { key: 'n', header: 'Rule', render: (r) => <><strong>{r.name}</strong><div className="muted small">{humanize(r.applies_to)} rule</div></> },
    { key: 's', header: 'Covers', render: (r) => <>{SCOPE_LABEL[r.scope]}<div className="muted small">{[r.vendor_name, r.category_name, r.service_category_name].filter(Boolean).join(' · ')}</div></> },
    { key: 'r', header: 'Rate', render: (r) => <strong>{rate(r)}</strong> },
    { key: 'p', header: 'Priority', align: 'right', render: (r) => r.priority },
    { key: 'w', header: 'Valid', render: (r) => <span className="small">{dateOnly(r.effective_from)}{r.effective_until ? ` – ${dateOnly(r.effective_until)}` : ' onward'}</span> },
    { key: 'st', header: 'Status', render: (r) => <StatusBadge status={r.state} /> },
    { key: 'a', header: '', align: 'right', render: (r) => <span className="row-actions"><Button size="sm" onClick={() => setEditing(r)}>Edit</Button><Button size="sm" onClick={() => setToggle(r)}>{r.is_active ? 'Deactivate' : 'Activate'}</Button></span> },
  ]

  return (
    <>
      <PageHeader title="Commission management" subtitle="What the platform keeps from each sale." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Commission management' }]} actions={<Button variant="primary" onClick={() => setEditing('new')}>New rule</Button>} />
      <div className="grid metrics">
        <MetricCard label="Commission earned (last 30 days)" value={summary.data ? money(summary.data.commission_earned) : '…'} hint="On vendor orders delivered in the period" tone="good" />
        <MetricCard label="Active rules" value={rules.data ? rules.data.filter((r) => r.state === 'active').length : '…'} />
      </div>
      <p className="note">The most specific active rule wins (vendor, then category, then every sale), then the higher priority. Two active rules with the same scope and priority that overlap in time are refused. Commission is recorded on each order when it is delivered, and past records never change. See each vendor order's commission under <Link to="/settlements">Vendor settlements</Link>.</p>
      <Card title="Rules">
        <DataTable caption="Commission rules" columns={columns} rows={rules.data} rowKey={(r) => r.id} loading={rules.loading} error={rules.error} onRetry={rules.reload} emptyTitle="No commission rules" emptyMessage="Without a matching rule, checkout follows the “missing commission rule” setting." />
      </Card>
      <Resolver />
      <Card title="Change history"><AuditTrail state={history} empty="No commission change has been recorded yet." /></Card>
      {editing && <RuleForm initial={editing === 'new' ? null : editing} onClose={() => setEditing(null)} onSaved={refresh} />}
      {toggle && (
        <ConfirmDialog title={toggle.is_active ? `Deactivate ${toggle.name}?` : `Activate ${toggle.name}?`} confirmLabel={toggle.is_active ? 'Deactivate' : 'Activate'} danger={toggle.is_active}
          message={toggle.is_active ? 'New orders will no longer use this rule. Orders already recorded keep their commission.' : 'New orders can use this rule again (the backend refuses if it conflicts with another active rule).'}
          onConfirm={async () => { await s.commission.update(toggle.id, { is_active: !toggle.is_active }); toast.success(toggle.is_active ? 'Rule deactivated.' : 'Rule activated.'); refresh() }} onClose={() => setToggle(null)} />
      )}
    </>
  )
}
