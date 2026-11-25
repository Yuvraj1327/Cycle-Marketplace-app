import { useState } from 'react'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, ConfirmDialog } from '../../components/common/ui'
import { CheckField, SelectField, TextField } from '../../components/forms/fields'
import { errorMessage } from '../../services/api/client'
import type { DeliveryChargeValue, Setting } from '../../types/api'
import { money } from '../../utils/format'

function Row({ setting, title, children, dirty, busy, onSave, error }: { setting: Setting; title: string; children: React.ReactNode; dirty: boolean; busy: boolean; onSave: () => void; error: string | null }) {
  return (
    <section className="setting-row" aria-label={title}>
      <h3>{title}</h3>
      <p className="muted small">{setting.description}</p>
      {!setting.configured && <p className="small"><em>Not set yet.</em> Current behaviour: {setting.default_behaviour}</p>}
      {children}
      {error && <p className="form-error" role="alert">{error}</p>}
      <Button variant="primary" size="sm" busy={busy} disabled={!dirty} onClick={onSave}>Save {title.toLowerCase()}</Button>
    </section>
  )
}

/** Shared save logic: one request to the backend (which validates and audits it); the screen shows the stored value that comes back. */
function useSave(setting: Setting, onSaved: () => void) {
  const s = useServices()
  const toast = useToast()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  async function save(value: unknown, label: string) {
    setBusy(true)
    setError(null)
    try {
      await s.settings.put(setting.key, value)
      toast.success(`${label} saved.`)
      onSaved()
    } catch (e) {
      setError(errorMessage(e))
    } finally {
      setBusy(false)
    }
  }
  return { busy, error, save }
}

export function BoolSetting({ setting, title, onLabel, confirmOff, onSaved }: { setting: Setting; title: string; onLabel: string; confirmOff?: string; onSaved: () => void }) {
  const current = typeof setting.value === 'boolean' ? setting.value : null
  const [value, setValue] = useState<boolean>(current ?? false)
  const [confirm, setConfirm] = useState(false)
  const { busy, error, save } = useSave(setting, onSaved)
  const dirty = current === null || value !== current
  const go = () => (confirmOff && current !== false && !value ? setConfirm(true) : void save(value, title))
  return (
    <Row setting={setting} title={title} dirty={dirty} busy={busy} onSave={go} error={error}>
      <CheckField label={onLabel} checked={value} onChange={setValue} />
      {confirm && <ConfirmDialog title={`Turn off ${title.toLowerCase()}?`} danger confirmLabel="Turn off" message={confirmOff} onConfirm={async () => { await save(value, title) }} onClose={() => setConfirm(false)} />}
    </Row>
  )
}

export function NumberSetting({ setting, title, label, min, max, unit, money: asMoney, onSaved }: { setting: Setting; title: string; label: string; min: number; max: number; unit?: string; money?: boolean; onSaved: () => void }) {
  const current = typeof setting.value === 'number' ? setting.value : null
  const [text, setText] = useState(current === null ? '' : String(current))
  const [touched, setTouched] = useState(false)
  const { busy, error, save } = useSave(setting, onSaved)
  const n = Number(text)
  const bad = text.trim() === '' || Number.isNaN(n) || n < min || n > max || (!asMoney && !Number.isInteger(n)) || (asMoney && !/^\d+(\.\d{1,2})?$/.test(text.trim()))
  const msg = asMoney ? `Enter an amount between ${money(min)} and ${money(max)} (two decimals at most).` : `Enter a whole number between ${min} and ${max}.`
  return (
    <Row setting={setting} title={title} dirty={current === null || n !== current} busy={busy} error={error} onSave={() => { setTouched(true); if (!bad) void save(asMoney ? Number(n.toFixed(2)) : n, title) }}>
      <TextField label={`${label}${unit ? ` (${unit})` : ''}`} required inputMode="decimal" value={text} onChange={setText} error={touched && bad ? msg : null} />
    </Row>
  )
}

export function ChoiceSetting({ setting, title, label, options, onSaved }: { setting: Setting; title: string; label: string; options: { value: string; label: string }[]; onSaved: () => void }) {
  const current = typeof setting.value === 'string' ? setting.value : null
  const [value, setValue] = useState(current ?? options[0].value)
  const { busy, error, save } = useSave(setting, onSaved)
  return (
    <Row setting={setting} title={title} dirty={current === null || value !== current} busy={busy} error={error} onSave={() => void save(value, title)}>
      <SelectField label={label} value={value} onChange={setValue} options={options} />
    </Row>
  )
}

export function DeliveryChargeSetting({ setting, onSaved }: { setting: Setting; onSaved: () => void }) {
  const cur = (setting.value && typeof setting.value === 'object' ? setting.value : null) as DeliveryChargeValue | null
  const [amount, setAmount] = useState(cur ? String(cur.amount) : '')
  const [free, setFree] = useState(cur?.free_above != null ? String(cur.free_above) : '')
  const [per, setPer] = useState<'order' | 'vendor_order'>(cur?.per ?? 'order')
  const [touched, setTouched] = useState(false)
  const { busy, error, save } = useSave(setting, onSaved)
  const money2 = (t: string) => /^\d+(\.\d{1,2})?$/.test(t.trim()) && Number(t) <= 100000
  const e: Record<string, string> = {}
  if (!money2(amount)) e.amount = 'Enter an amount between ₹0 and ₹100000 (two decimals at most).'
  if (free.trim() && !money2(free)) e.free = 'Enter an amount, or leave empty for no free-delivery threshold.'
  const dirty = !cur || Number(amount) !== cur.amount || (free.trim() === '' ? cur.free_above !== null : Number(free) !== cur.free_above) || per !== cur.per
  return (
    <Row setting={setting} title="Delivery charge" dirty={dirty} busy={busy} error={error} onSave={() => { setTouched(true); if (!Object.keys(e).length) void save({ amount: Number(amount), free_above: free.trim() ? Number(free) : null, per }, 'Delivery charge') }}>
      <div className="form-grid">
        <TextField label="Charge (₹)" required inputMode="decimal" value={amount} onChange={setAmount} error={touched ? e.amount : null} help="Use 0 for free delivery." />
        <TextField label="Free delivery above (₹)" inputMode="decimal" value={free} onChange={setFree} error={touched ? e.free : null} help="Optional order value above which delivery is free." />
        <SelectField label="Charged" value={per} onChange={setPer} options={[{ value: 'order', label: 'Once per order' }, { value: 'vendor_order', label: 'Once per vendor in the order' }]} />
      </div>
    </Row>
  )
}
