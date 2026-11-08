// Starts the LouVoice website server.
//   DATABASE_URL=postgres://... PORT=80 node server/index.mjs
// DATABASE_URL is the Tiger Data connection string for the read/insert-only `louvoice_web` role.
// It is read from the environment only: never put it in a file in this repo.

import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createApp } from './app.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const distDir = path.join(here, '..', 'dist')
const port = Number(process.env.PORT) || 3000

let db = null
if (process.env.DATABASE_URL) {
  const { default: pg } = await import('pg')
  db = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false },
    max: 5,
  })
  db.on('error', (err) => console.error(`database pool error: ${err.code ?? ''} ${err.message}`))
} else {
  console.warn('DATABASE_URL is not set: the site works, but the waitlist and progress chart are off.')
}

createApp({ db, distDir }).listen(port, () => console.log(`LouVoice site on http://localhost:${port}`))
