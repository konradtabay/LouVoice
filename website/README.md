# LouVoice website

Landing page for LouVoice (Vite + React + Tailwind + shadcn).

```bash
npm install
npm run dev      # http://localhost:5173
npm run build    # outputs dist/
```

Pages: `/` (home), `/purpose`, `/caregivers`. Routing is client-side, so the host must serve `index.html` for unknown paths; `vercel.json` does this on Vercel.
