// LouVoice mark: one stroke. The jawline curves down to the chin, then turns into a sound wave.
// Drawn in currentColor so it takes the surrounding text colour; Logo sets the brand purple.
// Source of truth for the shape: public/logo.svg and public/favicon.svg (keep them in sync).
export const MARK_PATH = 'M6 14C6 40 14 50 26 50C34 50 36 32 42 32C48 32 48 44 52 44C56 44 57 36 59 36'

export default function LogoMark({ className = 'h-9 w-auto' }: { className?: string }) {
  return (
    <svg viewBox="1.5 9.5 62 45" className={className} fill="none" aria-hidden>
      <path d={MARK_PATH} stroke="currentColor" strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}
