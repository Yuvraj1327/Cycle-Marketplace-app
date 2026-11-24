import type { ReactNode } from 'react'
import { EmptyState, ErrorState, Spinner } from '../common/ui'

export interface Column<T> {
  key: string
  header: string
  render: (row: T) => ReactNode
  align?: 'left' | 'right' | 'center'
  className?: string
}

interface Props<T> {
  columns: Column<T>[]
  rows: T[] | null
  rowKey: (row: T) => string
  loading?: boolean
  error?: unknown
  onRetry?: () => void
  onRowClick?: (row: T) => void
  emptyTitle?: string
  emptyMessage?: string
  caption: string
}

/** Table with loading / error / empty states. Wide tables scroll horizontally on small screens instead of breaking the layout. */
export function DataTable<T>({ columns, rows, rowKey, loading, error, onRetry, onRowClick, emptyTitle = 'Nothing to show', emptyMessage, caption }: Props<T>) {
  if (error && !rows?.length) return <ErrorState error={error} onRetry={onRetry} />
  const initial = loading && !rows?.length
  return (
    <div className="table-wrap" aria-busy={loading || undefined}>
      <table className="table">
        <caption className="sr-only">{caption}</caption>
        <thead>
          <tr>{columns.map((c) => <th key={c.key} scope="col" className={`align-${c.align ?? 'left'} ${c.className ?? ''}`}>{c.header}</th>)}</tr>
        </thead>
        <tbody className={loading && rows?.length ? 'dim' : ''}>
          {initial && (
            <tr><td colSpan={columns.length} className="table-state"><Spinner label="Loading rows" /> <span className="muted">Loading…</span></td></tr>
          )}
          {!initial && rows?.length === 0 && (
            <tr><td colSpan={columns.length} className="table-state"><EmptyState title={emptyTitle} message={emptyMessage} /></td></tr>
          )}
          {rows?.map((r) => (
            <tr key={rowKey(r)} className={onRowClick ? 'clickable' : ''} onClick={onRowClick ? () => onRowClick(r) : undefined}>
              {columns.map((c) => <td key={c.key} className={`align-${c.align ?? 'left'} ${c.className ?? ''}`}>{c.render(r)}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
