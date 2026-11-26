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

/** Smooth area/line chart of REAL per-day values (same data contract as DailyBars; nothing is estimated). */
export function AreaChart({ points, label, format = (n: number) => String(n), color = 'var(--c-green)' }: { points: Point[]; label: string; format?: (n: number) => string; color?: string }) {
  const id = useId()
  const total = points.reduce((s, p) => s + p.value, 0)
  if (total === 0) return <p className="muted chart-empty">No activity in this period.</p>
  const max = Math.max(1, ...points.map((p) => p.value))
  const w = 640
  const h = 270
  const pad = { l: 40, r: 12, t: 14, b: 26 }
  const iw = w - pad.l - pad.r
  const ih = h - pad.t - pad.b
  const x = (i: number) => pad.l + (points.length <= 1 ? iw / 2 : (i / (points.length - 1)) * iw)
  const y = (v: number) => pad.t + ih - (v / max) * ih
  // monotone-style smoothing: control points share the neighbour's x midpoint, so the curve never overshoots a real value
  const line = points.reduce((d, p, i) => {
    if (i === 0) return `M${x(0)} ${y(p.value)}`
    const mx = (x(i - 1) + x(i)) / 2
    return `${d} C${mx} ${y(points[i - 1].value)} ${mx} ${y(p.value)} ${x(i)} ${y(p.value)}`
  }, '')
  const area = `${line} L${x(points.length - 1)} ${pad.t + ih} L${x(0)} ${pad.t + ih} Z`
  const ticks = [...new Set([0, Math.ceil(max / 2), max])]
  const peak = points.reduce((b, p, i) => (p.value > points[b].value ? i : b), 0)
  const labelIdx = [...new Set(Array.from({ length: Math.min(points.length, 7) }, (_, k) => Math.round((k * (points.length - 1)) / Math.max(Math.min(points.length, 7) - 1, 1))))]
  return (
    <figure className="chart area-chart">
      <svg viewBox={`0 0 ${w} ${h}`} role="img" aria-labelledby={id} preserveAspectRatio="xMidYMid meet">
        <title id={id}>{label}</title>
        <defs>
          <linearGradient id={`${id}-fill`} x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity="0.32" />
            <stop offset="100%" stopColor={color} stopOpacity="0.02" />
          </linearGradient>
        </defs>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={pad.l} x2={w - pad.r} y1={y(t)} y2={y(t)} className="grid" />
            <text x={pad.l - 8} y={y(t) + 4} textAnchor="end" className="axis">{compactNumber(t)}</text>
          </g>
        ))}
        <path d={area} fill={`url(#${id}-fill)`} />
        <path d={line} fill="none" stroke={color} strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
        {points.map((p, i) => (
          <circle key={p.day} cx={x(i)} cy={y(p.value)} r={i === peak ? 5 : 9} className={i === peak ? 'area-peak' : 'area-hit'} fill={i === peak ? 'var(--c-surface)' : 'transparent'} stroke={i === peak ? color : 'none'} strokeWidth="2.5">
            <title>{`${shortDay(p.day)}: ${format(p.value)}`}</title>
          </circle>
        ))}
        {labelIdx.filter((i) => points[i]).map((i) => (
          <text key={i} x={x(i)} y={h - 8} textAnchor={i === 0 ? 'start' : i === points.length - 1 ? 'end' : 'middle'} className="axis">{shortDay(points[i].day)}</text>
        ))}
      </svg>
      <figcaption className="muted">{label} · total {format(total)}</figcaption>
    </figure>
  )
}

export interface DonutSlice {
  label: string
  value: number
  color: string
}

/** Ring chart of REAL counts with a legend (count and share). An all-zero ring is drawn empty rather than invented. */
export function Donut({ slices, total, centerLabel, label }: { slices: DonutSlice[]; total: number; centerLabel: string; label: string }) {
  const r = 52
  const c = 2 * Math.PI * r
  const pct = (v: number) => (total > 0 ? Math.round((v / total) * 100) : 0)
  return (
    <div className="donut-wrap">
      <div className="donut">
        <svg viewBox="0 0 140 140" role="img" aria-label={`${label}: ${slices.map((s) => `${s.label} ${s.value}`).join(', ')}`}>
          <circle cx="70" cy="70" r={r} fill="none" stroke="var(--c-line)" strokeWidth="14" />
          {total > 0 && slices.map((s, i) => {
            if (s.value <= 0) return null
            const len = (s.value / total) * c
            const before = slices.slice(0, i).reduce((n, x) => n + (x.value / total) * c, 0)
            return <circle key={s.label} cx="70" cy="70" r={r} fill="none" stroke={s.color} strokeWidth="14" strokeDasharray={`${len} ${c - len}`} strokeDashoffset={-before} transform="rotate(-90 70 70)" />
          })}
        </svg>
        <div className="donut-center"><strong>{total}</strong><span>{centerLabel}</span></div>
      </div>
      <table className="donut-legend">
        <tbody>
          {slices.map((s) => (
            <tr key={s.label}>
              <td><span className="dot" style={{ background: s.color }} aria-hidden="true" />{s.label}</td>
              <td className="num">{s.value}</td>
              <td className="num muted">{pct(s.value)}%</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
