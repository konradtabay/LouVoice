#!/usr/bin/env node
// Turns the Mac app's REAL recorded takes into SQL you can paste into the Tiger Data SQL editor.
//
//   node website/scripts/export-takes.mjs                 # reads the app's dataset.json, writes real-takes.sql
//   node website/scripts/export-takes.mjs path/to/dataset.json out.sql
//
// Each take becomes one row in word_attempts with source = 'real' and user_id = 'team-real'.
// movement_strength approximates the app's own strength check (Quality.strength): smoothed peak
// of |rotation| + 5·|acceleration| divided by the take's quiet (20th-percentile) level.
// No raw motion leaves the Mac: only the word, the time and that one number.

import { readFile, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import path from 'node:path'

const APPLE_EPOCH = 978307200 // Swift's default JSON dates are seconds since 2001-01-01

const input = process.argv[2] ?? path.join(homedir(), 'Library', 'Application Support', 'LouVoice', 'dataset.json')
const output = process.argv[3] ?? 'real-takes.sql'

const len = (v) => Math.hypot(v?.[0] ?? 0, v?.[1] ?? 0, v?.[2] ?? 0)

export function strength(samples) {
  const e = samples.map((s) => len(s.rotation) + 5 * len(s.accel))
  if (e.length < 3) return null
  const smooth = e.map((_, i) => {
    const w = e.slice(Math.max(0, i - 1), i + 2)
    return w.reduce((a, b) => a + b, 0) / w.length
  })
  const sorted = [...smooth].sort((a, b) => a - b)
  const quiet = Math.max(sorted[Math.floor(sorted.length / 5)], 1e-9)
  return sorted[sorted.length - 1] / quiet
}

const sql = (s) => `'${String(s).replace(/'/g, "''")}'`

export function toSql(dataset) {
  const rows = []
  for (const take of dataset.takes ?? []) {
    if (take.isSentence || !take.label || take.label.startsWith('_')) continue // words only, no "not a word" takes
    const s = strength(take.samples ?? [])
    if (s === null || !Number.isFinite(s)) continue
    const when = new Date((APPLE_EPOCH + Number(take.createdAt)) * 1000).toISOString()
    rows.push(`(${sql(when)}, 'team-real', ${sql(take.label)}, ${s.toFixed(2)}, NULL, NULL, false, 'real')`)
  }
  if (rows.length === 0) return null
  return [
    '-- Real takes recorded with the LouVoice Mac app. Paste into the Tiger SQL editor and run once.',
    'INSERT INTO word_attempts (time, user_id, word, movement_strength, confidence, correct, retrained, source) VALUES',
    rows.join(',\n') + ';',
    '',
    '-- Then run this on its own so the weekly summary picks them up:',
    "-- CALL refresh_continuous_aggregate('word_weekly', NULL, NULL);",
    '',
  ].join('\n')
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const dataset = JSON.parse(await readFile(input, 'utf8'))
  const text = toSql(dataset)
  if (!text) {
    console.error('No word takes found in', input)
    process.exit(1)
  }
  await writeFile(output, text)
  console.log(`Wrote ${text.split('\n').filter((l) => l.startsWith('(')).length} real takes to ${output}`)
}
