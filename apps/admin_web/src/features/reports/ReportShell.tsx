import type { ReactNode } from 'react'
import { useServices } from '../../app/providers/authContext'
import { Button, ErrorState, PageLoading, SelectFilter } from '../../components/common/ui'
import { DateRange } from '../../components/common/filters'
import { PageHeader } from '../../components/layout/PageHeader'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import type { Report, ReportKind } from '../../types/api'
import { dateOnly, lastDays } from '../../utils/format'

const PRESETS = [{ value: '', label: 'Choose…' }, { value: '7', label: 'Last 7 days' }, { value: '30', label: 'Last 30 days' }, { value: '90', label: 'Last 90 days' }, { value: '365', label: 'Last 12 months' }]

/** Common frame for every report: title, period controls (kept in the URL), loading / error states and the period actually reported. */
export function ReportShell<T>({ kind, title, subtitle, definition, children }: { kind: ReportKind; title: string; subtitle: string; definition: string; children: (data: T, report: Report<T>) => ReactNode }) {
  const s = useServices()
  const { values, set } = useListQuery(['from', 'to'] as const)
  const def = lastDays(30)
  const from = values.from || def.from
  const to = values.to || def.to
  const bad = from > to
  const report = useAsync(() => (bad ? Promise.reject(new Error('The start date must not be after the end date.')) : s.reports.get<T>(kind, from, to)), [kind, from, to])

  return (
    <>
      <PageHeader title={title} subtitle={subtitle} crumbs={[{ label: 'Overview', to: '/' }, { label: 'Reports' }, { label: title }]} actions={<Button onClick={report.reload}>Refresh</Button>} />
      <div className="card"><div className="toolbar" style={{ marginBottom: 0 }}>
        <SelectFilter label="Quick period" value="" onChange={(v) => { if (v) { const r = lastDays(Number(v)); set({ from: r.from, to: r.to }) } }} options={PRESETS} />
        <DateRange from={from} to={to} onChange={(r) => set({ from: r.from, to: r.to })} />
      </div>
      <p className="muted small" style={{ marginBottom: 0 }}>{bad ? 'The start date must not be after the end date.' : <>Period: {dateOnly(from)} to {dateOnly(to)} (India time). {definition}</>}</p></div>
      {report.loading && !report.data && <PageLoading label="Loading report…" />}
      {report.error && !report.data && <ErrorState error={report.error} onRetry={report.reload} />}
      {report.data && <div style={{ opacity: report.loading ? 0.6 : 1 }}>{children(report.data.data, report.data)}</div>}
    </>
  )
}
