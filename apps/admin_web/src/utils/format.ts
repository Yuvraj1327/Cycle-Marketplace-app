const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 })
const inrWhole = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 })

export function money(v: number | null | undefined): string {
  if (v === null || v === undefined || Number.isNaN(v)) return '—'
  return Number.isInteger(v) ? inrWhole.format(v) : inr.format(v)
}

export function compactNumber(v: number): string {
  return new Intl.NumberFormat('en-IN', { notation: 'compact', maximumFractionDigits: 1 }).format(v)
}

export type DateFormatId = 'D MMM YYYY' | 'DD/MM/YYYY' | 'MM/DD/YYYY' | 'YYYY-MM-DD'
export const DATE_FORMATS: DateFormatId[] = ['D MMM YYYY', 'DD/MM/YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD']
export const DEFAULT_TIMEZONE = 'Asia/Kolkata'
export const DEFAULT_DATE_FORMAT: DateFormatId = 'D MMM YYYY'

/** How dates are shown: the signed-in administrator's saved preferences (set by the preferences provider; the defaults are the platform's). */
let display: { timezone: string; dateFormat: DateFormatId } = { timezone: DEFAULT_TIMEZONE, dateFormat: DEFAULT_DATE_FORMAT }

export function setDisplayPreferences(p: { timezone?: string; dateFormat?: DateFormatId }): void {
  display = { timezone: p.timezone || DEFAULT_TIMEZONE, dateFormat: p.dateFormat || DEFAULT_DATE_FORMAT }
}

function parts(d: Date, timeZone: string | undefined) {
  const f = (o: Intl.DateTimeFormatOptions, locale = 'en-IN') => {
    try { return new Intl.DateTimeFormat(locale, { ...o, timeZone }).format(d) } catch { return new Intl.DateTimeFormat(locale, o).format(d) }
  }
  return { day: f({ day: 'numeric' }), dd: f({ day: '2-digit' }), mm: f({ month: '2-digit' }), mon: f({ month: 'short' }), year: f({ year: 'numeric' }) }
}

function formatDate(d: Date, timeZone: string | undefined): string {
  const p = parts(d, timeZone)
  switch (display.dateFormat) {
    case 'DD/MM/YYYY': return `${p.dd}/${p.mm}/${p.year}`
    case 'MM/DD/YYYY': return `${p.mm}/${p.dd}/${p.year}`
    case 'YYYY-MM-DD': return `${p.year}-${p.mm}-${p.dd}`
    default: return `${p.day} ${p.mon} ${p.year}`
  }
}

/** Date and time of an instant, in the preferred time zone and date format. */
export function dateTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  let time: string
  try { time = d.toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit', timeZone: display.timezone }) } catch { time = d.toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' }) }
  return `${formatDate(d, display.timezone)}, ${time}`
}

/** A calendar date. A plain `YYYY-MM-DD` day has no time zone, so it is never shifted; a full timestamp is shown in the preferred zone. */
export function dateOnly(iso: string | null | undefined): string {
  if (!iso) return '—'
  const dayOnly = iso.length === 10
  const d = new Date(dayOnly ? `${iso}T00:00:00` : iso)
  return Number.isNaN(d.getTime()) ? '—' : formatDate(d, dayOnly ? undefined : display.timezone)
}

export function shortDay(day: string): string {
  const d = new Date(`${day}T00:00:00`)
  return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })
}

export function humanize(s: string | null | undefined): string {
  if (!s) return '—'
  return s.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase())
}

export function shortId(id: string): string {
  return id.slice(0, 8)
}

export function isoDay(d: Date): string {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const dd = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${dd}`
}

/** Inclusive local-date window ending today: lastDays(7) = today and the 6 days before. */
export function lastDays(n: number): { from: string; to: string } {
  const to = new Date()
  const from = new Date()
  from.setDate(to.getDate() - (n - 1))
  return { from: isoDay(from), to: isoDay(to) }
}

export function initials(name: string | null | undefined, email: string | null | undefined): string {
  const src = (name || email || '?').trim()
  const parts = src.split(/[\s@.]+/).filter(Boolean)
  return ((parts[0]?.[0] ?? '?') + (parts[1]?.[0] ?? '')).toUpperCase()
}
