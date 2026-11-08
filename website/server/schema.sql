-- LouVoice: Tiger Data (TimescaleDB) setup.
-- Paste each block into the Tiger Console SQL editor and run them in order, A to F.
-- Run this as the admin user from your service's config file (tsdbadmin).

-- ─── Block A: training attempts, as a hypertable ────────────────────────────
-- One row per time a word was mouthed. A hypertable is TimescaleDB's time-series table.
CREATE TABLE IF NOT EXISTS word_attempts (
  time              TIMESTAMPTZ NOT NULL,
  user_id           TEXT NOT NULL,
  word              TEXT NOT NULL,
  movement_strength DOUBLE PRECISION,  -- peak jaw motion ÷ resting noise floor
  confidence        DOUBLE PRECISION,  -- recognizer confidence, 0 to 1
  correct           BOOLEAN,
  retrained         BOOLEAN DEFAULT false,
  source            TEXT NOT NULL      -- 'real' or 'simulated'
);
SELECT create_hypertable('word_attempts', by_range('time'), if_not_exists => TRUE);

-- ─── Block B: SIMULATED 6-month progression for the demo ────────────────────
-- ~4,500 rows. Movement strength fades over 180 days; accuracy slips and each word is
-- retrained every 60 days. Every row is marked source = 'simulated'. Always say so in the pitch.
INSERT INTO word_attempts (time, user_id, word, movement_strength, confidence, correct, retrained, source)
SELECT
  now() - interval '180 days' + make_interval(days => day, hours => 9 + rep * 2),
  'alex-demo',
  w.word,
  round((w.base * (1 - 0.5 * day / 180.0) + (random() - 0.5) * 0.4)::numeric, 2),
  round(least(1, greatest(0, 0.92 - 0.30 * ((day % 60) / 60.0) - 0.10 * day / 180.0 + (random() - 0.5) * 0.1))::numeric, 2),
  random() < (0.92 - 0.30 * ((day % 60) / 60.0) - 0.10 * day / 180.0),
  (day % 60 = 0 AND rep = 0),
  'simulated'
FROM generate_series(0, 179) AS day,
     generate_series(0, 4)   AS rep,
     (VALUES ('hello', 6.0), ('can', 4.5), ('you', 5.0), ('hear', 5.5), ('me', 4.0)) AS w(word, base);

-- ─── Block C: the weekly curve, as a continuous aggregate ───────────────────
CREATE MATERIALIZED VIEW IF NOT EXISTS word_weekly
WITH (timescaledb.continuous) AS
SELECT time_bucket('7 days', time) AS week,
       user_id,
       word,
       avg(movement_strength)                     AS avg_strength,
       avg(CASE WHEN correct THEN 1 ELSE 0 END)   AS accuracy,
       count(*)                                   AS attempts
FROM word_attempts
GROUP BY week, user_id, word;

CALL refresh_continuous_aggregate('word_weekly', NULL, NULL);

-- Keep it fresh as new attempts arrive (hourly).
SELECT add_continuous_aggregate_policy('word_weekly',
  start_offset => INTERVAL '30 days',
  end_offset   => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour',
  if_not_exists => TRUE);

-- ─── Block D: check it worked ────────────────────────────────────────────────
-- Strength should shrink week over week.
SELECT week, word, round(avg_strength::numeric, 2) AS strength, round(accuracy::numeric, 2) AS acc
FROM word_weekly
WHERE user_id = 'alex-demo'
ORDER BY week, word
LIMIT 20;

-- ─── Block E: a limited login for the website ───────────────────────────────
-- Replace the password with your own long random one before running.
CREATE ROLE louvoice_web LOGIN PASSWORD 'REPLACE-WITH-A-LONG-RANDOM-PASSWORD';
GRANT USAGE ON SCHEMA public TO louvoice_web;
GRANT SELECT ON word_weekly TO louvoice_web;

-- ─── Block F: the waitlist ──────────────────────────────────────────────────
-- The website can ADD emails but never READ them. Check sign-ups yourself as tsdbadmin.
CREATE TABLE IF NOT EXISTS waitlist (
  id           BIGSERIAL PRIMARY KEY,
  email        TEXT NOT NULL UNIQUE,              -- stored lowercased by the server
  signed_up_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source       TEXT
);
GRANT INSERT ON waitlist TO louvoice_web;
GRANT USAGE ON SEQUENCE waitlist_id_seq TO louvoice_web;

-- See who signed up (admin only):
-- SELECT count(*) FROM waitlist;
-- SELECT email, signed_up_at FROM waitlist ORDER BY signed_up_at DESC;
