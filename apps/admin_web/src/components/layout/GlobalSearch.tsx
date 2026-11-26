import { useEffect, useId, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useDebounce } from '../../hooks/useDebounce'
import { money } from '../../utils/format'

interface Hit {
  to: string
  title: string
  detail: string
}
interface Group {
  label: string
  hits: Hit[]
}

const MIN_CHARS = 2
const PER_GROUP = 4

/** Top-bar search across customers, vendors, orders and products. It only calls the existing admin list endpoints (`q`), once the administrator types. */
export function GlobalSearch() {
  const s = useServices()
  const id = useId()
  const inputRef = useRef<HTMLInputElement>(null)
  const boxRef = useRef<HTMLDivElement>(null)
  const [text, setText] = useState('')
  const [open, setOpen] = useState(false)
  const q = useDebounce(text.trim(), 300)
  const [state, setState] = useState<{ q: string; groups: Group[]; failed: boolean } | null>(null)
  const active = q.length >= MIN_CHARS
  const loading = active && state?.q !== q

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        inputRef.current?.focus()
        inputRef.current?.select()
        setOpen(true)
      }
    }
    const onDown = (e: MouseEvent) => !boxRef.current?.contains(e.target as Node) && setOpen(false)
    document.addEventListener('keydown', onKey)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('mousedown', onDown)
    }
  }, [])

  useEffect(() => {
    if (!active) return
    let alive = true
    const p = { q, limit: PER_GROUP }
    void Promise.allSettled([
      s.customers.list(p),
      s.vendors.list(p),
      s.orders.list(p),
      s.products.list(p),
    ]).then(([c, v, o, pr]) => {
      if (!alive) return
      const groups: Group[] = []
      if (c.status === 'fulfilled') groups.push({ label: 'Customers', hits: c.value.items.map((x) => ({ to: `/customers/${x.id}`, title: x.full_name || x.email || 'Unnamed customer', detail: x.email ?? x.phone ?? '' })) })
      if (v.status === 'fulfilled') groups.push({ label: 'Vendors', hits: v.value.items.map((x) => ({ to: `/vendors/${x.id}`, title: x.business_name, detail: x.city })) })
      if (o.status === 'fulfilled') groups.push({ label: 'Orders', hits: o.value.items.map((x) => ({ to: `/orders/${x.id}`, title: x.order_number, detail: `${x.customer?.full_name ?? 'Customer'} · ${money(x.total_amount)}` })) })
      if (pr.status === 'fulfilled') groups.push({ label: 'Products', hits: pr.value.items.map((x) => ({ to: `/products/${x.id}`, title: x.name, detail: money(x.price) })) })
      setState({ q, groups: groups.filter((g) => g.hits.length > 0), failed: [c, v, o, pr].every((r) => r.status === 'rejected') })
    })
    return () => { alive = false }
  }, [s, q, active])

  const close = () => { setOpen(false); inputRef.current?.blur() }
  const panel = open && text.trim().length > 0

  return (
    <div className="gsearch" ref={boxRef} role="search">
      <label className="gsearch-field">
        <span className="sr-only">Search customers, vendors, orders, products</span>
        <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" d="m21 21-4.3-4.3M10.5 18a7.5 7.5 0 1 1 0-15 7.5 7.5 0 0 1 0 15Z" /></svg>
        <input
          ref={inputRef}
          type="search"
          value={text}
          maxLength={100}
          placeholder="Search customers, vendors, orders, products…"
          aria-controls={id}
          aria-expanded={panel}
          autoComplete="off"
          onChange={(e) => { setText(e.target.value); setOpen(true) }}
          onFocus={() => setOpen(true)}
          onKeyDown={(e) => e.key === 'Escape' && close()}
        />
        <kbd aria-hidden="true">⌘ K</kbd>
      </label>
      {panel && (
        <div className="gsearch-panel" id={id} role="region" aria-label="Search results" aria-live="polite">
          {!active && <p className="muted small gsearch-note">Type at least {MIN_CHARS} characters.</p>}
          {active && loading && <p className="muted small gsearch-note">Searching…</p>}
          {active && !loading && state?.failed && <p className="gsearch-note small form-error">Search is unavailable right now.</p>}
          {active && !loading && state && !state.failed && state.groups.length === 0 && <p className="muted small gsearch-note">No matches for “{q}”.</p>}
          {active && !loading && state?.groups.map((g) => (
            <div key={g.label} className="gsearch-group">
              <p className="gsearch-label">{g.label}</p>
              <ul>
                {g.hits.map((h) => (
                  <li key={h.to}>
                    <Link to={h.to} onClick={() => { setText(''); close() }}><strong>{h.title}</strong>{h.detail && <span className="muted">{h.detail}</span>}</Link>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
