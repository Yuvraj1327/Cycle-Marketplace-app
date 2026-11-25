import { ErrorState, EmptyState, Spinner } from '../../components/common/ui'
import type { AsyncState } from '../../hooks/useAsync'
import type { AuditRecord, Page } from '../../types/api'
import { dateTime, humanize } from '../../utils/format'

function summary(d: Record<string, unknown>): string {
  const parts = Object.entries(d).filter(([, v]) => v !== null && v !== undefined && typeof v !== 'object').slice(0, 5).map(([k, v]) => `${humanize(k)}: ${String(v)}`)
  return parts.join(' · ')
}

/** Who did what, from the backend audit log (read-only). */
export function AuditTrail({ state, empty = 'Nothing recorded yet.' }: { state: AsyncState<Page<AuditRecord>>; empty?: string }) {
  if (state.loading && !state.data) return <Spinner label="Loading history" />
  if (state.error && !state.data) return <ErrorState compact error={state.error} onRetry={state.reload} />
  const rows = state.data?.items ?? []
  if (rows.length === 0) return <EmptyState title="No history" message={empty} />
  return (
    <ol className="timeline">
      {rows.map((a) => (
        <li key={a.id}>
          <strong>{humanize(a.action)}</strong> <span className="muted small">{dateTime(a.created_at)} · {a.actor_name ?? a.actor_role ?? 'System'}</span>
          {summary(a.details) && <p className="muted small">{summary(a.details)}</p>}
        </li>
      ))}
    </ol>
  )
}
