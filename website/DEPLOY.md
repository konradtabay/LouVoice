# Deploying the LouVoice website (Vultr + Tiger Data)

The site is a Vite + React app. `server/` is a small Node server that serves the built site and two APIs:

| Endpoint | What it does | Tiger Data object |
|---|---|---|
| `POST /api/waitlist` | Stores a waitlist email (trimmed, lowercased, rate-limited, honeypot) | `waitlist` table (website can insert, never read) |
| `GET /api/progress` | Weekly movement strength + accuracy per word | `word_weekly` continuous aggregate over the `word_attempts` hypertable |

The progress section on `/caregivers` only appears when `/api/progress` returns data, so the site still works without a database.

> On Vercel (the old `vercel.json` setup) there is no Node server, so the waitlist form will show an error. Use Vultr.

---

## 1. Tiger Data (about 15 min, browser only)

1. Sign up at mlh.link/tigerdata-quickstart, open the **web console**, click **New service**.
2. Pick **0.5 CPU** (covered by trial credits) in **US East (Ohio)** or **US East (N. Virginia)**. Name it `louvoice`.
3. **Download the config file.** It's the only time the admin password is shown.
4. Open the service's **SQL editor** and run `server/schema.sql` block by block (A → F).
   - Before Block E, replace the password with a long random one made of **letters and digits only** (symbols would need URL-encoding in step 5).
5. Build the website's connection string from the config file's host and port, using the `louvoice_web` login:

   ```
   postgres://louvoice_web:<YOUR_PASSWORD>@<HOST>:<PORT>/tsdb?sslmode=require
   ```

   Never commit this string or put it in a file in the repo.

## 2. Try it on your Mac (optional, 5 min)

```bash
cd website
npm install
npm run build
read -s DATABASE_URL   # paste the string, press Enter (hidden)
export DATABASE_URL
npm start              # http://localhost:3000
```

Check: join the waitlist twice with the same email in different capitals → only one row in `SELECT * FROM waitlist;` (run as the admin in the Tiger SQL editor). `/caregivers` shows the two charts.

`npm run test:server` runs the server tests (no database needed).

## 3. Vultr (about 20 min)

1. Sign up at mlh.link/vultr-signup. **Billing → apply the promo code** from the team's sponsor notes.
2. **Deploy → Cloud Compute → Shared CPU → Toronto → Ubuntu 24.04 →** the 1 GB plan. Deploy, then copy the **IP** and **root password**.
3. **Upload the site** from your Mac (run in the repo root; skips `node_modules` and `dist`):

   ```bash
   tar --exclude=node_modules --exclude=dist -czf - website | ssh root@YOUR_IP 'tar -xzf - -C /root'
   ```

4. **On the server** (`ssh root@YOUR_IP`), one line at a time:

   ```bash
   # Node 22 (Ubuntu's built-in Node 18 is too old for Vite 8)
   curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
   apt install -y nodejs

   cd /root/website
   npm install
   npm run build

   npm install -g pm2
   read -s DATABASE_URL   # paste the louvoice_web string, press Enter
   export DATABASE_URL
   PORT=80 pm2 start server/index.mjs --name louvoice
   pm2 save
   pm2 startup systemd    # keeps it running after a reboot

   # Firewall: SSH first, or you lock yourself out
   ufw allow OpenSSH && ufw allow 80 && ufw --force enable
   ```

5. Open `http://YOUR_IP` and `http://YOUR_IP/caregivers`.

If `npm run build` is killed (out of memory on 1 GB), add swap and retry:

```bash
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
```

### Updating the live site

Re-run the upload command from step 3, then on the server:

```bash
cd /root/website && npm install && npm run build && pm2 restart louvoice
```

### Optional: a real domain with HTTPS (about 15 min)

1. Claim a domain with the GoDaddy Registry code from the sponsor notes. In its DNS settings add an **A record**: host `@`, value = the Vultr IP. Wait a few minutes.
2. On the server, move Node off port 80 and put Caddy in front (it gets the HTTPS certificate by itself):

   ```bash
   pm2 delete louvoice
   PORT=3000 pm2 start server/index.mjs --name louvoice && pm2 save
   apt install -y caddy
   echo 'YOURDOMAIN.com {
     reverse_proxy localhost:3000
   }' > /etc/caddy/Caddyfile
   systemctl reload caddy
   ufw allow 443
   ```

   (Run `read -s DATABASE_URL && export DATABASE_URL` again first if you've logged out since step 4.)
3. Open `https://YOURDOMAIN.com`.

## 4. Real data from the Mac app (optional, 5 min)

Puts the team's real recorded takes into Tiger next to the simulated curve. Only the word, the time and one strength number leave the Mac, never raw motion.

On the Mac that recorded the sessions, from the repo root:

```bash
node website/scripts/export-takes.mjs          # writes real-takes.sql
```

Open `real-takes.sql`, paste it into the Tiger SQL editor, select all, **Run selection** once. Then run this on its own:

```sql
CALL refresh_continuous_aggregate('word_weekly', NULL, NULL);
```

The `/caregivers` page then shows a "Real data so far" line under the charts. Don't commit `real-takes.sql`.

---

## Checking the waitlist

In the Tiger SQL editor, as the admin:

```sql
SELECT count(*) FROM waitlist;
SELECT email, signed_up_at FROM waitlist ORDER BY signed_up_at DESC;
```

Signing up for a clearly described list is the consent Canada's anti-spam law expects; `signed_up_at` is the record of it. Only email people about LouVoice, and honour unsubscribes.
