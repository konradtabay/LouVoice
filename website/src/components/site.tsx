import { useState, type ReactNode } from 'react'
import { ArrowRight, Menu, X } from 'lucide-react'
import Dither from '@/components/Dither'
import Logo from '@/components/Logo'
import { Link, usePath } from '@/router'
import { WaitlistForm, openWaitlist } from '@/components/Waitlist'

/* Shared pieces used by every page. */

export const NAV: [string, string][] = [
  ['Purpose', '/purpose'],
  ['Caregivers', '/caregivers'],
]

export const WRAP = 'mx-auto max-w-[1680px] px-5 sm:px-8 xl:w-[calc(100%-4rem)] xl:px-0'

export function Header() {
  const path = usePath()
  const [open, setOpen] = useState(false)
  return (
    <header className="relative z-20 mx-auto max-w-[1680px] border-b border-ink px-5 sm:px-8 lg:mx-8 lg:px-0 xl:mx-auto xl:w-[calc(100%-4rem)]">
      <div className="flex items-center justify-between py-5">
        <Logo />
        <nav aria-label="Main" className="hidden items-center gap-10 md:flex">
          {NAV.map(([label, to]) => {
            const active = path === to
            return (
              <Link
                key={to}
                to={to}
                aria-current={active ? 'page' : undefined}
                className={`relative py-2 text-[17px] ${active ? 'font-semibold text-ink' : 'text-ink/65 hover:text-ink'}`}
              >
                {label}
                {active && <span className="absolute -bottom-[21px] left-0 h-0.5 w-full bg-ink" />}
              </Link>
            )
          })}
        </nav>
        {/* keeps the nav centred; the waitlist button floats in once the page hero is passed */}
        <span aria-hidden className="hidden w-[190px] md:block" />
        <div className="flex items-center gap-3 md:hidden">
          <button
            className="grid size-11 place-items-center border border-ink md:hidden"
            aria-expanded={open}
            aria-controls="mobile-nav"
            aria-label={open ? 'Close menu' : 'Open menu'}
            onClick={() => setOpen(!open)}
          >
            {open ? <X className="size-5" /> : <Menu className="size-5" />}
          </button>
        </div>
      </div>
      {open && (
        <nav id="mobile-nav" aria-label="Main" className="flex flex-col border-t border-ink py-2 md:hidden">
          {NAV.map(([label, to]) => (
            <Link
              key={to}
              to={to}
              onClick={() => setOpen(false)}
              aria-current={path === to ? 'page' : undefined}
              className={`py-3 text-[19px] ${path === to ? 'font-semibold' : 'text-ink/75'}`}
            >
              {label}
            </Link>
          ))}
        </nav>
      )}
    </header>
  )
}

export function ClosingCTA() {
  return (
    <section id="join" className="relative overflow-hidden bg-ink text-pearl">
      <div className="absolute inset-0 opacity-90">
        <Dither ditherMode="bayer" palette={['#010101', '#5b3629', '#682bd7', '#a37cf0']} pixelSize={3} waveSpeed={0.03} scale={1.4} mouseEffect="ripple" />
      </div>
      <div aria-hidden className="pointer-events-none absolute inset-0 bg-gradient-to-r from-ink/85 via-ink/40 to-transparent" />
      <div className={`relative flex flex-col items-start gap-10 py-28 lg:py-40 ${WRAP}`}>
        <h2 className="display max-w-[12ch] text-[clamp(60px,9vw,140px)]">Start while your words are strong.</h2>
        <WaitlistForm dark />
        <span className="text-[16px] text-pearl/75">AirPods Pro 2 · macOS 14+ · A student project, not a medical device · © 2026 LouVoice</span>
      </div>
    </section>
  )
}

/* ——— building blocks for the inner pages ——— */

export function PageHero({ title, intro, art }: { title: ReactNode; intro: ReactNode; art?: ReactNode }) {
  return (
    <section className="relative overflow-hidden border-b border-ink">
      <div aria-hidden className="grid-lines pointer-events-none absolute top-0 right-0 bottom-0 left-[58%] hidden lg:block" />
      {art && <div aria-hidden className="pointer-events-none absolute top-0 right-0 bottom-0 left-[64%] hidden lg:block">{art}</div>}
      <div className={`relative py-20 lg:py-28 ${WRAP}`}>
        <h1 className="display max-w-[14ch] text-[clamp(48px,6.2vw,100px)] lg:max-w-[58%]">{title}</h1>
        <div className="mt-10 max-w-[36rem] text-[19px] leading-[1.65] text-ink/85 sm:text-[21px]">{intro}</div>
      </div>
    </section>
  )
}

export function Section({ title, aside, children, id }: { title: ReactNode; aside?: ReactNode; children: ReactNode; id?: string }) {
  return (
    <section id={id} className={`py-20 lg:py-28 ${WRAP}`}>
      <div className="flex flex-wrap items-end justify-between gap-6 border-b border-ink pb-8">
        <h2 className="display max-w-[16ch] text-[clamp(40px,5vw,76px)]">{title}</h2>
        {aside && <div className="max-w-md text-[18px] leading-relaxed text-ink/75">{aside}</div>}
      </div>
      {children}
    </section>
  )
}

/** Numbered rows: number + title on the left, body on the right. */
export function Rows({ items }: { items: { title: string; body: ReactNode }[] }) {
  return (
    <ol className="divide-y divide-ink border-b border-ink">
      {items.map(({ title, body }, i) => (
        <li key={title} className="grid gap-4 py-8 md:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] md:gap-10">
          <div className="flex items-baseline gap-5">
            <span className="font-mono text-[13px] text-ink/55">{String(i + 1).padStart(2, '0')}</span>
            <h3 className="display text-[clamp(28px,2.6vw,40px)]">{title}</h3>
          </div>
          <div className="max-w-[40rem] text-[17px] leading-relaxed text-ink/80">{body}</div>
        </li>
      ))}
    </ol>
  )
}

/** Bordered card grid, same look as the home "How it works" cards. */
export function Cards({ items, cols = 3 }: { items: { label?: string; title: string; body: ReactNode }[]; cols?: 2 | 3 | 4 }) {
  const grid = cols === 2 ? 'md:grid-cols-2' : cols === 4 ? 'md:grid-cols-2 lg:grid-cols-4' : 'md:grid-cols-3'
  return (
    <div className={`grid gap-px border-b border-ink bg-ink ${grid}`}>
      {items.map(({ label, title, body }) => (
        <article key={title} className="paper flex flex-col gap-4 p-8">
          {label && <span className="font-mono text-[12px] tracking-wide text-ink/55 uppercase">{label}</span>}
          <h3 className="display text-[clamp(28px,2.4vw,38px)]">{title}</h3>
          <div className="text-[17px] leading-relaxed text-ink/75">{body}</div>
        </article>
      ))}
    </div>
  )
}

export function Quote({ children, cite }: { children: ReactNode; cite: ReactNode }) {
  return (
    <figure className="border-l-2 border-heart py-2 pl-6">
      <blockquote className="font-heading text-[clamp(22px,2vw,30px)] leading-snug">{children}</blockquote>
      <figcaption className="mt-3 text-[14px] text-ink/60">{cite}</figcaption>
    </figure>
  )
}

export function FloatingWaitlist({ show }: { show: boolean }) {
  return (
    <button
      type="button"
      onClick={openWaitlist}
      aria-hidden={!show}
      tabIndex={show ? 0 : -1}
      className={`fixed top-4 right-4 z-50 inline-flex h-12 items-center gap-2.5 rounded-lg bg-ink px-5 text-[15px] font-semibold text-pearl shadow-[4px_4px_0_#682bd7] transition-all duration-300 hover:bg-[#3d1689] sm:top-5 sm:right-6 ${
        show ? 'translate-y-0 opacity-100' : 'pointer-events-none -translate-y-4 opacity-0'
      }`}
    >
      Join the waitlist <ArrowRight className="size-4" />
    </button>
  )
}
