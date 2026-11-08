import { useEffect, useMemo, useState } from 'react'
import { Section } from '@/components/site'

/**
 * "How it tracks change": weekly movement strength and accuracy per word, read from
 * Tiger Data through GET /api/progress (website/server). Hand-drawn SVG, no chart library.
 * If the API isn't there (e.g. a static-only host), the section doesn't render.
 */

type Row = { week: string; word: string; strength: number; accuracy: number }

// Distinct in lightness as well as hue, so lines stay apart without colour alone.
const COLORS = ['#010101', '#3d1689', '#682bd7', '#bd2e95', '#a37cf0']
const DASHES = ['', '8 5', '', '3 4', '12 4']

const W = 640
const H = 280
const PAD = { top: 16, right: 16, bottom: 36, left: 52 }

function LineChart({
  title,
  rows,
  words,
  value,
  max,
  format,
}: {
  title: string
  rows: Row[]
  words: string[]
  value: (r: Row) => number
  max: number
  format: (v: number) => string
}) {
  const weeks = useMemo(() => [...new Set(rows.map((r) => r.week))].sort(), [rows])
  const x = (i: number) => PAD.left + (i / Math.max(weeks.length - 1, 1)) * (W - PAD.left - PAD.right)
  const y = (v: number) => PAD.top + (1 - v / max) * (H - PAD.top - PAD.bottom)
  const ticks = [0, max / 2, max]
  const monthLabel = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { month: 'short' })

  return (
    <figure className="flex flex-col gap-3">
      <figcaption className="display text-[clamp(22px,2vw,30px)]">{title}</figcaption>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${title}, by word, over time`} className="w-full">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={PAD.left} x2={W - PAD.right} y1={y(t)} y2={y(t)} stroke="#010101" strokeOpacity={0.15} />
            <text x={PAD.left - 8} y={y(t) + 4} textAnchor="end" fontSize={12} fill="#010101" fillOpacity={0.6}>
              {format(t)}
            </text>
          </g>
        ))}
        {weeks.map((w, i) =>
          i % 4 === 0 ? (
            <text key={w} x={x(i)} y={H - 12} textAnchor="middle" fontSize={12} fill="#010101" fillOpacity={0.6}>
              {monthLabel(w)}
            </text>
          ) : null,
        )}
        {words.map((word, wi) => {
          const pts = weeks
            .map((wk, i) => {
              const r = rows.find((row) => row.week === wk && row.word === word)
              return r ? `${x(i).toFixed(1)},${y(Math.min(value(r), max)).toFixed(1)}` : null
            })
            .filter(Boolean)
            .join(' ')
          return (
            <polyline
              key={word}
              points={pts}
              fill="none"
              stroke={COLORS[wi % COLORS.length]}
              strokeWidth={2.5}
              strokeDasharray={DASHES[wi % DASHES.length]}
              strokeLinejoin="round"
            />
          )
        })}
      </svg>
    </figure>
  )
}

export default function ProgressChart() {
  const [rows, setRows] = useState<Row[] | null>(null)

  useEffect(() => {
    let alive = true
    fetch('/api/progress')
      .then((r) => (r.ok ? r.json() : null))
      .then((d: { rows?: Row[] } | null) => alive && setRows(d?.rows?.length ? d.rows : []))
      .catch(() => alive && setRows([]))
    return () => {
      alive = false
    }
  }, [])

  const words = useMemo(() => [...new Set((rows ?? []).map((r) => r.word))], [rows])
  if (!rows || rows.length === 0) return null

  const maxStrength = Math.ceil(Math.max(...rows.map((r) => r.strength), 1))

  return (
    <Section
      id="progress"
      title="How it tracks change"
      aside="Every time a word is mouthed, LouVoice logs how strong the movement was and whether it understood. When a word slips, it asks to retrain just that word."
    >
      <div className="grid gap-10 pt-10 lg:grid-cols-2">
        <LineChart title="Movement strength" rows={rows} words={words} value={(r) => r.strength} max={maxStrength} format={(v) => v.toFixed(0)} />
        <LineChart title="Accuracy" rows={rows} words={words} value={(r) => r.accuracy} max={1} format={(v) => `${Math.round(v * 100)}%`} />
      </div>
      <ul className="mt-6 flex flex-wrap gap-x-6 gap-y-2 text-[15px]">
        {words.map((w, i) => (
          <li key={w} className="flex items-center gap-2">
            <svg width="28" height="8" aria-hidden="true">
              <line x1="0" x2="28" y1="4" y2="4" stroke={COLORS[i % COLORS.length]} strokeWidth={3} strokeDasharray={DASHES[i % DASHES.length]} />
            </svg>
            “{w}”
          </li>
        ))}
      </ul>
      <p className="mt-4 text-[14px] text-ink/60">
        Simulated 6-month progression for demonstration. Stored in Tiger Data (TimescaleDB hypertable and continuous aggregate).
      </p>
    </Section>
  )
}
