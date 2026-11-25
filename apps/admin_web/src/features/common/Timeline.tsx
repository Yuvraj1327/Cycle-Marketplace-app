import { EmptyState, ErrorState, Spinner, StatusBadge } from '../../components/common/ui'
import type { AsyncState } from '../../hooks/useAsync'
import type { TimelineEvent } from '../../types/api'
import { dateTime, humanize } from '../../utils/format'

/** Status history from the backend's history tables (read-only). */
export function Timeline({ state }: { state: AsyncState<TimelineEvent[]> }) {
  if (state.loading && !state.data) return <Spinner label="Loading history" />
  if (state.error && !state.data) return <ErrorState compact error={state.error} onRetry={state.reload} />
  const rows = state.data ?? []
  if (rows.length === 0) return <EmptyState title="No status changes recorded" />
  return (
    <ol className="timeline">
      {rows.map((e, i) => (
        <li key={`${e.at}-${i}`}>
          {e.from_status ? <><StatusBadge status={e.from_status} /> → </> : null}<StatusBadge status={e.to_status} />
          {e.vendor_name && <span className="muted small"> · {e.vendor_name}</span>}
          <div className="muted small">{dateTime(e.at)} · {e.changed_by_name ?? (e.changed_by_role ? humanize(e.changed_by_role) : 'System')}{e.changed_by_role && e.changed_by_name ? ` (${humanize(e.changed_by_role)})` : ''}</div>
          {e.note && <p>{e.note}</p>}
        </li>
      ))}
    </ol>
  )
}
