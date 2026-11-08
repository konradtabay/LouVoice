import { useEffect, useState } from 'react'
import { Section } from '@/components/site'

/**
 * "How it tracks change": weekly movement strength and accuracy, averaged across all of a
 * user's words, read from Tiger Data through GET /api/progress (website/server).
 * Hand-drawn SVG, no chart library. If the API isn't there, the section doesn't render.
 */

type Row = { week: string; strength: number; accuracy: number }
type Real = { attempts: number; strength: number } | null

const W = 640
const H = 280
const PAD = { top: 16, right: 16, bottom: 36, left: 52 }
const LINE = '#682bd7'

function LineChart({
  title,
  rows,
  value,
  max,
  format,
}: {
  title: string
  rows: Row[]
  value: (r: Row) => number
  max: number
  format: (v: number) => string
}) {
  const x = (i: number) => PAD.left + (i / Math.max(rows.length - 1, 1)) * (W - PAD.left - PAD.right)
  const y = (v: number) => PAD.top + (1 - v / max) * (H - PAD.top - PAD.bottom)
  const ticks = [0, max / 2, max]
  const monthLabel = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { month: 'short' })
  const points = rows.map((r, i) => `${x(i).toFixed(1)},${y(Math.min(value(r), max)).toFixed(1)}`).join(' ')
  const first = rows[0]
  const last = rows[rows.length - 1]

  return (
    <figure className="flex flex-col gap-3">
      <figcaption className="flex items-baseline justify-between gap-4">
        <span className="display text-[clamp(22px,2vw,30px)]">{title}</span>
        <span className="font-mono text-[14px] text-ink/60">
          {format(value(first))} → {format(value(last))}
        </span>
      </figcaption>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${title} over time, from ${format(value(first))} to ${format(value(last))}`} className="w-full">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={PAD.left} x2={W - PAD.right} y1={y(t)} y2={y(t)} stroke="#010101" strokeOpacity={0.15} />
            <text x={PAD.left - 8} y={y(t) + 4} textAnchor="end" fontSize={12} fill="#010101" fillOpacity={0.6}>
              {format(t)}
            </text>
          </g>
        ))}
        {rows.map((r, i) =>
          i % 4 === 0 ? (
            <text key={r.week} x={x(i)} y={H - 12} textAnchor="middle" fontSize={12} fill="#010101" fillOpacity={0.6}>
              {monthLabel(r.week)}
            </text>
          ) : null,
        )}
        <polyline points={points} fill="none" stroke={LINE} strokeWidth={3} strokeLinejoin="round" strokeLinecap="round" />
      </svg>
    </figure>
  )
}

export default function ProgressChart() {
  const [rows, setRows] = useState<Row[] | null>(null)
  const [real, setReal] = useState<Real>(null)

  useEffect(() => {
    let alive = true
    fetch('/api/progress')
      .then((r) => (r.ok ? r.json() : null))
      .then((d: { rows?: Row[]; real?: Real } | null) => {
        if (!alive) return
        setRows(d?.rows?.length ? d.rows : [])
        setReal(d?.real ?? null)
      })
      .catch(() => alive && setRows([]))
    return () => {
      alive = false
    }
  }, [])

  if (!rows || rows.length < 2) return null

  const maxStrength = Math.ceil(Math.max(...rows.map((r) => r.strength), 1))

  return (
    <Section
      id="progress"
      title="How it tracks change"
      aside="Every time a word is mouthed, LouVoice logs how strong the movement was and whether it understood. When a word slips, it asks to retrain just that word."
    >
      <div className="grid gap-10 pt-10 lg:grid-cols-2">
        <LineChart title="Movement strength" rows={rows} value={(r) => r.strength} max={maxStrength} format={(v) => `${v.toFixed(1)}×`} />
        <LineChart title="Accuracy" rows={rows} value={(r) => r.accuracy} max={1} format={(v) => `${Math.round(v * 100)}%`} />
      </div>
      {real && (
        <p className="mt-6 text-[17px] font-semibold">
          Real data so far: {real.attempts} mouthed words recorded by our team with AirPods, at an average movement strength of{' '}
          {real.strength.toFixed(1)}×.
        </p>
      )}
      <p className="mt-4 text-[14px] text-ink/60">
        Charts: simulated 6-month progression for demonstration, averaged across all words. All data is stored in Tiger Data
        (TimescaleDB hypertable and continuous aggregate).
      </p>
    </Section>
  )
}
