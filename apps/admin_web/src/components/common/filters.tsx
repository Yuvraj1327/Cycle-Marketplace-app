import type { ReactNode } from 'react'

/** Two date inputs (YYYY-MM-DD). Empty = no bound. The backend applies platform-local days. */
export function DateRange({ from, to, onChange }: { from: string; to: string; onChange: (v: { from: string; to: string }) => void }) {
  return (
    <>
      <label className="filter"><span>From</span><input type="date" value={from} max={to || undefined} onChange={(e) => onChange({ from: e.target.value, to })} /></label>
      <label className="filter"><span>To</span><input type="date" value={to} min={from || undefined} onChange={(e) => onChange({ from, to: e.target.value })} /></label>
    </>
  )
}

export interface TabDef { value: string; label: string }

export function Tabs({ label, tabs, value, onChange }: { label: string; tabs: TabDef[]; value: string; onChange: (v: string) => void }) {
  return (
    <div className="tabs" role="tablist" aria-label={label}>
      {tabs.map((t) => (
        <button key={t.value} type="button" role="tab" aria-selected={value === t.value} className={value === t.value ? 'tab active' : 'tab'} onClick={() => onChange(t.value)}>{t.label}</button>
      ))}
    </div>
  )
}

export function FormGrid({ children }: { children: ReactNode }) {
  return <div className="form-grid">{children}</div>
}
