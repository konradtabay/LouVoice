// LouVoice website server: serves the built Vite site (dist/) and two small APIs.
// Uses only Node built-ins here; the database is passed in, so tests can use a fake.
//
//   POST /api/waitlist  {email, company?}  -> stores the email in Tiger Data (waitlist table)
//   GET  /api/progress                     -> weekly movement strength + accuracy per word (word_weekly)

import { createServer } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import path from 'node:path'

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const MAX_BODY_BYTES = 2048
const RATE_LIMIT = 5 // waitlist requests per IP per window
const RATE_WINDOW_MS = 60_000

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
}

/** Trim + lowercase, then validate. Returns the clean email or null. */
export function cleanEmail(raw) {
  if (typeof raw !== 'string') return null
  const email = raw.trim().toLowerCase()
  if (email.length === 0 || email.length > 254 || !EMAIL_RE.test(email)) return null
  return email
}

/** In-memory sliding window: max `limit` hits per `windowMs` per key. */
export function makeRateLimiter(limit = RATE_LIMIT, windowMs = RATE_WINDOW_MS, now = () => Date.now()) {
  const hits = new Map()
  return function allow(key) {
    const t = now()
    const recent = (hits.get(key) ?? []).filter((ts) => t - ts < windowMs)
    if (recent.length >= limit) {
      hits.set(key, recent)
      return false
    }
    recent.push(t)
    hits.set(key, recent)
    if (hits.size > 10_000) hits.clear() // crude cap so memory can't grow forever
    return true
  }
}

function send(res, status, body, headers = {}) {
  const isJson = typeof body !== 'string' && !Buffer.isBuffer(body)
  res.writeHead(status, {
    'Content-Type': isJson ? 'application/json; charset=utf-8' : headers['Content-Type'] ?? 'text/plain; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    ...headers,
  })
  res.end(isJson ? JSON.stringify(body) : body)
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (c) => {
      size += c.length
      if (size > MAX_BODY_BYTES) {
        reject(new Error('too_large'))
        req.destroy()
      } else chunks.push(c)
    })
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'))
      } catch {
        reject(new Error('bad_json'))
      }
    })
    req.on('error', reject)
  })
}

function clientIp(req) {
  // Only trust X-Forwarded-For when explicitly told we're behind a proxy.
  if (process.env.TRUST_PROXY === '1') {
    const fwd = req.headers['x-forwarded-for']
    if (typeof fwd === 'string' && fwd) return fwd.split(',')[0].trim()
  }
  return req.socket.remoteAddress ?? 'unknown'
}

/**
 * @param {{ db: { query: (sql: string, params?: unknown[]) => Promise<{ rows: any[] }> } | null,
 *           distDir: string, log?: (msg: string) => void }} opts
 */
export function createApp({ db, distDir, log = (m) => console.error(m) }) {
  const allow = makeRateLimiter()
  const root = path.resolve(distDir)

  async function waitlist(req, res) {
    if (!allow(clientIp(req))) return send(res, 429, { ok: false, message: 'Too many tries. Please wait a minute.' })
    let body
    try {
      body = await readJson(req)
    } catch {
      return send(res, 400, { ok: false, message: 'Please enter a valid email.' })
    }
    // Honeypot: real people never fill the hidden "company" field. Pretend it worked.
    if (body && typeof body.company === 'string' && body.company.trim() !== '') return send(res, 200, { ok: true })
    const email = cleanEmail(body?.email)
    if (!email) return send(res, 400, { ok: false, message: 'Please enter a valid email.' })
    if (!db) return send(res, 503, { ok: false, message: 'Sign-ups are paused right now. Please try again soon.' })
    try {
      await db.query('INSERT INTO waitlist (email, source) VALUES ($1, $2)', [email, 'website'])
    } catch (err) {
      // Already on the list: say yes anyway, so the form never reveals who signed up.
      if (err && err.code === '23505') return send(res, 200, { ok: true })
      log(`waitlist insert failed: ${err?.code ?? ''} ${err?.message ?? err}`) // never logs the email
      return send(res, 500, { ok: false, message: 'Something went wrong. Please try again.' })
    }
    return send(res, 200, { ok: true })
  }

  async function progress(_req, res) {
    if (!db) return send(res, 503, { ok: false, rows: [] })
    try {
      // One overall line: averaged across all words, so the public page never lists the vocabulary.
      const { rows } = await db.query(
        `SELECT week,
                sum(avg_strength * attempts) / nullif(sum(attempts), 0) AS avg_strength,
                sum(accuracy * attempts) / nullif(sum(attempts), 0)     AS accuracy
           FROM word_weekly
          WHERE user_id = 'alex-demo'
          GROUP BY week
          ORDER BY week`,
      )
      // Real takes recorded by the team (exported from the Mac app): one overall total.
      const real = await db.query(
        `SELECT sum(attempts)::int AS attempts,
                sum(avg_strength * attempts) / nullif(sum(attempts), 0) AS strength
           FROM word_weekly
          WHERE user_id = 'team-real'`,
      )
      const r0 = real.rows[0]
      return send(res, 200, {
        ok: true,
        simulated: true,
        rows: rows.map((r) => ({
          week: new Date(r.week).toISOString(),
          strength: Number(r.avg_strength),
          accuracy: Number(r.accuracy),
        })),
        real: r0 && Number(r0.attempts) > 0 ? { attempts: Number(r0.attempts), strength: Number(r0.strength) } : null,
      }, { 'Cache-Control': 'public, max-age=60' })
    } catch (err) {
      log(`progress query failed: ${err?.code ?? ''} ${err?.message ?? err}`)
      return send(res, 500, { ok: false, rows: [] })
    }
  }

  async function serveFile(file, res, cache) {
    const data = await readFile(file)
    send(res, 200, data, {
      'Content-Type': TYPES[path.extname(file).toLowerCase()] ?? 'application/octet-stream',
      'Cache-Control': cache,
    })
  }

  async function staticOrIndex(req, res) {
    let pathname
    try {
      pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname)
    } catch {
      return send(res, 400, 'Bad request')
    }
    const file = path.resolve(root, '.' + pathname)
    if (file !== root && !file.startsWith(root + path.sep)) return send(res, 403, 'Forbidden') // no ../ escapes
    try {
      const s = await stat(file)
      if (s.isFile()) {
        const hashed = pathname.startsWith('/assets/')
        return await serveFile(file, res, hashed ? 'public, max-age=31536000, immutable' : 'public, max-age=300')
      }
    } catch {
      /* fall through */
    }
    // A path with a file extension that doesn't exist is a real 404; everything else is a client-side route.
    if (path.extname(pathname)) return send(res, 404, 'Not found')
    try {
      return await serveFile(path.join(root, 'index.html'), res, 'no-cache')
    } catch {
      return send(res, 500, 'Site not built. Run `npm run build` first.')
    }
  }

  return createServer(async (req, res) => {
    try {
      const url = req.url ?? '/'
      if (url === '/api/waitlist' || url.startsWith('/api/waitlist?')) {
        if (req.method !== 'POST') return send(res, 405, { ok: false }, { Allow: 'POST' })
        return await waitlist(req, res)
      }
      if (url === '/api/progress' || url.startsWith('/api/progress?')) {
        if (req.method !== 'GET') return send(res, 405, { ok: false }, { Allow: 'GET' })
        return await progress(req, res)
      }
      if (url.startsWith('/api/')) return send(res, 404, { ok: false })
      if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method not allowed', { Allow: 'GET, HEAD' })
      return await staticOrIndex(req, res)
    } catch (err) {
      log(`request failed: ${err?.message ?? err}`)
      if (!res.headersSent) send(res, 500, 'Server error')
      else res.end()
    }
  })
}
