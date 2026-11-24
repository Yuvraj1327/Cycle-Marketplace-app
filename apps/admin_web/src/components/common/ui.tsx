import { useEffect, useId, useRef, useState, type ButtonHTMLAttributes, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { ApiError, errorMessage } from '../../services/api/client'
import { humanize } from '../../utils/format'

export function Spinner({ label = 'Loading' }: { label?: string }) {
  return <span className="spinner" role="status" aria-label={label} />
}

export function PageLoading({ label = 'Loading…' }: { label?: string }) {
  return (
    <div className="center-block" role="status">
      <Spinner label={label} />
      <p className="muted">{label}</p>
    </div>
  )
}

type BtnVariant = 'primary' | 'secondary' | 'danger' | 'ghost'
interface BtnProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: BtnVariant
  busy?: boolean
  size?: 'md' | 'sm'
}

/** Button with a built-in busy state: disabled while a request is in flight, so double submissions are impossible. */
export function Button({ variant = 'secondary', busy = false, size = 'md', children, disabled, className = '', type = 'button', ...rest }: BtnProps) {
  return (
    <button type={type} className={`btn btn-${variant} btn-${size} ${className}`} disabled={disabled || busy} aria-busy={busy || undefined} {...rest}>
      {busy && <Spinner label="Working" />}
      {children}
    </button>
  )
}

const TONES: Record<string, string> = {
  // verification / account
  approved: 'green', active: 'green', completed: 'green', delivered: 'green', successful: 'green', paid: 'green', confirmed: 'blue',
  pending: 'amber', processing: 'amber', open: 'amber', in_service: 'amber',
  rejected: 'red', suspended: 'red', cancelled: 'red', failed: 'red', restricted: 'orange', inactive: 'gray',
  accepted: 'blue', refunded: 'purple',
}

export function StatusBadge({ status, label }: { status: string | null | undefined; label?: string }) {
  if (!status) return <span className="muted">—</span>
  return <span className={`badge badge-${TONES[status] ?? 'gray'}`}>{label ?? humanize(status)}</span>
}

export function MetricCard({ label, value, hint, to, tone = 'default', icon }: { label: string; value: ReactNode; hint?: ReactNode; to?: string; tone?: 'default' | 'warn' | 'good' | 'bad'; icon?: ReactNode }) {
  const body = (
    <>
      <div className="metric-top">
        <span className="metric-label">{label}</span>
        {icon && <span className="metric-icon" aria-hidden="true">{icon}</span>}
      </div>
      <div className="metric-value">{value}</div>
      {hint && <div className="metric-hint">{hint}</div>}
    </>
  )
  return to ? <Link to={to} className={`card metric metric-${tone} metric-link`}>{body}</Link> : <div className={`card metric metric-${tone}`}>{body}</div>
}

export function Card({ title, actions, children, className = '' }: { title?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`card ${className}`}>
      {(title || actions) && (
        <header className="card-head">
          {title && <h2 className="card-title">{title}</h2>}
          {actions && <div className="card-actions">{actions}</div>}
        </header>
      )}
      {children}
    </section>
  )
}

export function EmptyState({ title, message, action }: { title: string; message?: string; action?: ReactNode }) {
  return (
    <div className="empty" role="status">
      <div className="empty-art" aria-hidden="true">∅</div>
      <h3>{title}</h3>
      {message && <p className="muted">{message}</p>}
      {action}
    </div>
  )
}

export function ErrorState({ error, onRetry, compact = false }: { error: unknown; onRetry?: () => void; compact?: boolean }) {
  const offline = error instanceof ApiError && error.isNetwork
  return (
    <div className={`error-state ${compact ? 'compact' : ''}`} role="alert">
      <strong>{offline ? 'You appear to be offline' : 'Something went wrong'}</strong>
      <p>{errorMessage(error)}</p>
      {onRetry && <Button size="sm" onClick={onRetry}>Try again</Button>}
    </div>
  )
}

export function Modal({ title, onClose, children, footer, wide = false }: { title: string; onClose: () => void; children: ReactNode; footer?: ReactNode; wide?: boolean }) {
  const titleId = useId()
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null
    ref.current?.focus()
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      prev?.focus?.()
    }
  }, [onClose])
  return (
    <div className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal ${wide ? 'modal-wide' : ''}`} role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1} ref={ref}>
        <header className="modal-head">
          <h2 id={titleId}>{title}</h2>
          <button type="button" className="icon-btn" aria-label="Close" onClick={onClose}>×</button>
        </header>
        <div className="modal-body">{children}</div>
        {footer && <footer className="modal-foot">{footer}</footer>}
      </div>
    </div>
  )
}

interface ConfirmProps {
  title: string
  message: ReactNode
  confirmLabel: string
  danger?: boolean
  /** Ask for a reason. `reasonRequired` enforces 3+ characters before the action can be submitted. */
  reasonLabel?: string
  reasonRequired?: boolean
  /** Must resolve only once the BACKEND has confirmed; rejects (throws) to keep the dialog open and show the error. */
  onConfirm: (reason: string) => Promise<void>
  onClose: () => void
}

/** Confirmation dialog for sensitive actions. It stays open and shows the backend's error if the action fails; it closes only after success. */
export function ConfirmDialog({ title, message, confirmLabel, danger = false, reasonLabel, reasonRequired = false, onConfirm, onClose }: ConfirmProps) {
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const needs = reasonLabel !== undefined && reasonRequired
  const tooShort = needs && reason.trim().length < 3

  async function submit() {
    if (busy || tooShort) return
    setBusy(true)
    setError(null)
    try {
      await onConfirm(reason.trim())
      onClose()
    } catch (e) {
      setError(errorMessage(e))
      setBusy(false)
    }
  }

  return (
    <Modal
      title={title}
      onClose={busy ? () => undefined : onClose}
      footer={
        <>
          <Button onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant={danger ? 'danger' : 'primary'} busy={busy} disabled={tooShort} onClick={() => void submit()}>{confirmLabel}</Button>
        </>
      }
    >
      <div className="confirm-message">{message}</div>
      {reasonLabel !== undefined && (
        <label className="field">
          <span>{reasonLabel}{reasonRequired ? ' *' : ''}</span>
          <textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={3} maxLength={500} aria-required={reasonRequired} placeholder="At least 3 characters" />
        </label>
      )}
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

export function SearchInput({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder: string }) {
  return (
    <label className="search">
      <span className="sr-only">Search</span>
      <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" d="m21 21-4.3-4.3M10.5 18a7.5 7.5 0 1 1 0-15 7.5 7.5 0 0 1 0 15Z" /></svg>
      <input type="search" value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} maxLength={100} />
    </label>
  )
}

export function SelectFilter<T extends string>({ label, value, onChange, options }: { label: string; value: T; onChange: (v: T) => void; options: { value: T; label: string }[] }) {
  return (
    <label className="filter">
      <span>{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value as T)}>
        {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    </label>
  )
}

export function Pagination({ page, pages, total, limit, onPage }: { page: number; pages: number; total: number; limit: number; onPage: (p: number) => void }) {
  if (total === 0) return null
  const from = (page - 1) * limit + 1
  const to = Math.min(total, page * limit)
  return (
    <nav className="pagination" aria-label="Pagination">
      <span className="muted">{from}–{to} of {total}</span>
      <div className="pagination-btns">
        <Button size="sm" disabled={page <= 1} onClick={() => onPage(page - 1)}>Previous</Button>
        <span className="page-ind">Page {page} of {Math.max(pages, 1)}</span>
        <Button size="sm" disabled={page >= pages} onClick={() => onPage(page + 1)}>Next</Button>
      </div>
    </nav>
  )
}

export function KeyValue({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl className="kv">
      {rows.map(([k, v]) => (
        <div key={k} className="kv-row">
          <dt>{k}</dt>
          <dd>{v ?? '—'}</dd>
        </div>
      ))}
    </dl>
  )
}
