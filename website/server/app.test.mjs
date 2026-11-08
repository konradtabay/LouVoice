// Run: npm run test:server   (Node's built-in test runner, no extra packages)
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { createApp, cleanEmail, makeRateLimiter } from './app.mjs'

let dist
let server
let base
const inserted = []
const logs = []

// Fake database: behaves like a UNIQUE email column, and serves two progress rows.
const db = {
  async query(sql, params = []) {
    if (sql.startsWith('INSERT INTO waitlist')) {
      if (params[0] === 'boom@example.com') throw Object.assign(new Error('connection lost'), { code: '08006' })
      if (inserted.includes(params[0])) throw Object.assign(new Error('duplicate key'), { code: '23505' })
      inserted.push(params[0])
      return { rows: [] }
    }
    if (sql.includes("'team-real'")) {
      return { rows: [{ attempts: 12, strength: '6.4' }] }
    }
    if (sql.includes('FROM word_weekly')) {
      assert.match(sql, /GROUP BY week/) // averaged across words, never per word
      return {
        rows: [
          { week: new Date('2026-05-01T00:00:00Z'), avg_strength: '5.9', accuracy: '0.9' },
          { week: new Date('2026-05-08T00:00:00Z'), avg_strength: '5.7', accuracy: '0.85' },
        ],
      }
    }
    throw new Error('unexpected query')
  },
}

before(async () => {
  dist = await mkdtemp(path.join(tmpdir(), 'louvoice-dist-'))
  await mkdir(path.join(dist, 'assets'))
  await writeFile(path.join(dist, 'index.html'), '<!doctype html><title>LouVoice</title>')
  await writeFile(path.join(dist, 'assets', 'app-abc123.js'), 'console.log(1)')
  server = createApp({ db, distDir: dist, log: (m) => logs.push(m) })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  base = `http://127.0.0.1:${server.address().port}`
})

after(async () => {
  await new Promise((r) => server.close(r))
  await rm(dist, { recursive: true, force: true })
})

const join = (body) =>
  fetch(`${base}/api/waitlist`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })

test('cleanEmail trims, lowercases and validates', () => {
  assert.equal(cleanEmail('  Neel@Example.COM '), 'neel@example.com')
  assert.equal(cleanEmail('not-an-email'), null)
  assert.equal(cleanEmail('a@b.c'.padStart(255, 'x')), null)
  assert.equal(cleanEmail(42), null)
})

test('waitlist stores one lowercased row, and a duplicate still says ok', async () => {
  const first = await join({ email: 'Kathy@Example.com' })
  assert.equal(first.status, 200)
  assert.deepEqual(await first.json(), { ok: true })
  const again = await join({ email: '  KATHY@example.COM ' })
  assert.equal(again.status, 200)
  assert.deepEqual(await again.json(), { ok: true })
  assert.deepEqual(inserted, ['kathy@example.com'])
})

test('waitlist rejects a bad email', async () => {
  const res = await join({ email: 'nope' })
  assert.equal(res.status, 400)
  assert.equal((await res.json()).ok, false)
})

test('honeypot pretends to succeed and stores nothing', async () => {
  const before = inserted.length
  const res = await join({ email: 'bot@spam.com', company: 'Spam Inc' })
  assert.equal(res.status, 200)
  assert.equal(inserted.length, before)
})

test('database errors return a generic message and never log the email', async () => {
  const res = await join({ email: 'boom@example.com' })
  assert.equal(res.status, 500)
  assert.ok(!logs.join('\n').includes('boom@example.com'))
})

test('rate limiter allows 5 per window, then blocks, then recovers', () => {
  let t = 0
  const allow = makeRateLimiter(5, 60_000, () => t)
  for (let i = 0; i < 5; i++) assert.equal(allow('ip'), true)
  assert.equal(allow('ip'), false)
  assert.equal(allow('other-ip'), true)
  t = 61_000
  assert.equal(allow('ip'), true)
})

test('progress returns numbers and ISO dates', async () => {
  const res = await fetch(`${base}/api/progress`)
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.equal(body.simulated, true)
  assert.deepEqual(body.rows[0], { week: '2026-05-01T00:00:00.000Z', strength: 5.9, accuracy: 0.9 })
  assert.deepEqual(body.real, { attempts: 12, strength: 6.4 })
  assert.doesNotMatch(JSON.stringify(body), /"word"/) // no vocabulary in the public response
})

test('export script turns app takes into real-data SQL', async () => {
  const { toSql, strength } = await import('../scripts/export-takes.mjs')
  const still = { rotation: [0.01, 0, 0], accel: [0.001, 0, 0] }
  const moving = { rotation: [0.5, 0.2, 0], accel: [0.05, 0, 0] }
  const samples = [still, still, still, still, moving, moving, still, still, still, still]
  assert.ok(strength(samples) > 3)
  const text = toSql({
    takes: [
      { label: "it's", createdAt: 0, samples },
      { label: '_none', createdAt: 0, samples },
      { label: 'hello can you', isSentence: true, createdAt: 0, samples },
    ],
  })
  assert.match(text, /'2001-01-01T00:00:00.000Z', 'team-real', 'it''s'/) // Apple epoch + escaped quote
  assert.doesNotMatch(text, /_none|hello can you/)
  assert.equal(toSql({ takes: [] }), null)
})

test('wrong methods are refused', async () => {
  assert.equal((await fetch(`${base}/api/waitlist`)).status, 405)
  assert.equal((await fetch(`${base}/api/progress`, { method: 'POST' })).status, 405)
})

test('static files, client-side routes and 404s', async () => {
  const asset = await fetch(`${base}/assets/app-abc123.js`)
  assert.equal(asset.status, 200)
  assert.match(asset.headers.get('cache-control'), /immutable/)
  const route = await fetch(`${base}/caregivers`)
  assert.equal(route.status, 200)
  assert.match(await route.text(), /LouVoice/)
  assert.equal((await fetch(`${base}/missing.png`)).status, 404)
})

test('cannot escape the dist folder', async () => {
  const res = await fetch(`${base}/%2e%2e/%2e%2e/etc/passwd`)
  assert.ok([403, 404].includes(res.status) || !(await res.text()).includes('root:'))
})

test('without a database, the waitlist says it is paused', async () => {
  const noDb = createApp({ db: null, distDir: dist, log: () => {} })
  await new Promise((r) => noDb.listen(0, '127.0.0.1', r))
  const res = await fetch(`http://127.0.0.1:${noDb.address().port}/api/waitlist`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'a@b.co' }),
  })
  assert.equal(res.status, 503)
  await new Promise((r) => noDb.close(r))
})
