import { useId } from 'react'
import { compactNumber, shortDay } from '../../utils/format'

interface Point {
  day: string
  value: number
}

/** Daily bar chart of REAL per-day values. A day with no records is a real zero: nothing is estimated or smoothed. */
export function DailyBars({ points, label, format = (n: number) => String(n), color = 'var(--c-primary)' }: { points: Point[]; label: string; format?: (n: number) => string; color?: string }) {
  const id = useId()
  const max = Math.max(1, ...points.map((p) => p.value))
  const total = points.reduce((s, p) => s + p.value, 0)
  const w = 640
  const h = 180
  const pad = { l: 36, r: 8, t: 10, b: 24 }
  const iw = w - pad.l - pad.r
  const ih = h - pad.t - pad.b
  const bw = iw / Math.max(points.length, 1)
  const ticks = [0, Math.ceil(max / 2), max]
  if (total === 0) return <p className="muted chart-empty">No activity in this period.</p>
  return (
    <figure className="chart">
      <svg viewBox={`0 0 ${w} ${h}`} role="img" aria-labelledby={id} preserveAspectRatio="xMidYMid meet">
        <title id={id}>{label}</title>
        {ticks.map((t) => {
          const y = pad.t + ih - (t / max) * ih
          return (
            <g key={t}>
              <line x1={pad.l} x2={w - pad.r} y1={y} y2={y} className="grid" />
              <text x={pad.l - 6} y={y + 4} textAnchor="end" className="axis">{compactNumber(t)}</text>
            </g>
          )
        })}
        {points.map((p, i) => {
          const bh = (p.value / max) * ih
          return (
            <g key={p.day}>
              <rect x={pad.l + i * bw + bw * 0.15} y={pad.t + ih - bh} width={bw * 0.7} height={Math.max(bh, p.value > 0 ? 1 : 0)} rx={2} fill={color}>
                <title>{`${shortDay(p.day)}: ${format(p.value)}`}</title>
              </rect>
            </g>
          )
        })}
        {[0, Math.floor((points.length - 1) / 2), points.length - 1].filter((v, i, a) => a.indexOf(v) === i && points[v]).map((i) => (
          <text key={i} x={pad.l + i * bw + bw / 2} y={h - 6} textAnchor="middle" className="axis">{shortDay(points[i].day)}</text>
        ))}
      </svg>
      <figcaption className="muted">{label} · total {format(total)}</figcaption>
    </figure>
  )
}

/** Horizontal distribution bars (e.g. orders by status) from real counts. */
export function DistributionBars({ rows }: { rows: { label: string; value: number; tone?: string }[] }) {
  const total = rows.reduce((s, r) => s + r.value, 0)
  if (total === 0) return <p className="muted chart-empty">No records yet.</p>
  const max = Math.max(...rows.map((r) => r.value))
  return (
    <ul className="dist">
      {rows.map((r) => (
        <li key={r.label}>
          <span className="dist-label">{r.label}</span>
          <span className="dist-track"><span className={`dist-fill tone-${r.tone ?? 'blue'}`} style={{ width: `${(r.value / max) * 100}%` }} /></span>
          <span className="dist-val">{r.value}</span>
        </li>
      ))}
    </ul>
  )
}
