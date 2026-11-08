# LouVoice website

Landing page for LouVoice (Vite + React + Tailwind + shadcn).

```bash
npm install
npm run dev      # http://localhost:5173
npm run build    # outputs dist/
```

With the API (waitlist + progress chart, needs `DATABASE_URL`): `npm run build && npm start` → http://localhost:3000. During `npm run dev`, `/api` is proxied to that server. Hosting on Vultr with Tiger Data: see [DEPLOY.md](DEPLOY.md).

Pages: `/` (home), `/purpose`, `/caregivers`. Routing is client-side, so the host must serve `index.html` for unknown paths; `vercel.json` does this on Vercel.
