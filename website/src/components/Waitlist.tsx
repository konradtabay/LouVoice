import { useEffect, useRef, useState, type FormEvent } from 'react'
import { ArrowRight, X } from 'lucide-react'
import LogoMark from '@/components/LogoMark'

/** Open the waitlist popup from anywhere: <button onClick={openWaitlist}>. */
export function openWaitlist() {
  window.dispatchEvent(new Event('open-waitlist'))
}

/** Email + one button. Nothing else. */
export function WaitlistForm({ dark = false, autoFocus = false }: { dark?: boolean; autoFocus?: boolean }) {
  const [email, setEmail] = useState('')
  const [company, setCompany] = useState('') // honeypot: hidden from people, bots fill it in
  const [error, setError] = useState<string | null>(null)
  const [sending, setSending] = useState(false)
  const [done, setDone] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (sending) return
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) return setError('Enter a valid email.')
    setSending(true)
    try {
      // Stored in Tiger Data by website/server (POST /api/waitlist).
      const res = await fetch('/api/waitlist', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: email.trim(), company }),
      })
      const data = (await res.json().catch(() => null)) as { ok?: boolean; message?: string } | null
      if (res.ok && data?.ok) setDone(true)
      else setError(data?.message ?? 'Something went wrong. Please try again.')
    } catch {
      setError('Couldn’t reach the server. Please try again.')
    } finally {
      setSending(false)
    }
  }

  if (done)
    return (
      <p role="status" className={`flex items-center gap-3 text-[17px] sm:text-[18px] font-semibold ${dark ? 'text-pearl' : 'text-ink'}`}>
        <LogoMark className={`h-7 w-auto ${dark ? 'text-portage' : 'text-[#3d1689]'}`} /> You’re on the list. We’ll email you.
      </p>
    )

  return (
    <form onSubmit={submit} noValidate className="flex w-full max-w-[34rem] flex-col gap-2">
      <div className="flex flex-col gap-3 sm:flex-row">
        <input
          type="email"
          required
          autoFocus={autoFocus}
          autoComplete="email"
          aria-label="Email"
          aria-invalid={error !== null}
          placeholder="you@email.com"
          value={email}
          onChange={(e) => { setEmail(e.target.value); setError(null) }}
          className={`h-14 w-full min-w-0 rounded-lg border px-5 text-[17px] sm:h-16 sm:flex-1 sm:text-[18px] outline-none transition focus:ring-2 ${
            dark
              ? 'border-pearl/60 bg-ink/40 text-pearl placeholder:text-pearl/50 focus:border-pearl focus:ring-portage/50'
              : 'border-ink bg-pearl text-ink placeholder:text-ink/40 focus:border-[#3d1689] focus:ring-[#3d1689]/30'
          }`}
        />
        <input
          type="text"
          name="company"
          tabIndex={-1}
          autoComplete="off"
          aria-hidden="true"
          value={company}
          onChange={(e) => setCompany(e.target.value)}
          className="sr-only"
        />
        <button
          type="submit"
          disabled={sending}
          className={`inline-flex h-14 w-full shrink-0 items-center justify-center gap-3 rounded-lg px-8 text-[17px] sm:h-16 sm:w-auto sm:text-[18px] font-semibold transition active:translate-y-px disabled:opacity-60 ${
            dark ? 'bg-pearl text-ink hover:bg-portage' : 'bg-ink text-pearl shadow-[5px_5px_0_#682bd7] hover:bg-[#3d1689]'
          }`}
        >
          {sending ? 'Joining…' : 'Join the waitlist'} <ArrowRight className="size-5" />
        </button>
      </div>
      {error && <p role="alert" className={`text-[14px] font-semibold ${dark ? 'text-portage' : 'text-[#bd2e95]'}`}>{error}</p>}
      <p className={`text-[14px] ${dark ? 'text-pearl/70' : 'text-ink/60'}`}>We’ll only email you about LouVoice. Unsubscribe anytime.</p>
    </form>
  )
}

/** Mounted once; any openWaitlist() call shows it. */
export function WaitlistPopup() {
  const ref = useRef<HTMLDialogElement>(null)
  const [key, setKey] = useState(0)

  useEffect(() => {
    const open = () => {
      setKey((k) => k + 1) // fresh form each time
      ref.current?.showModal()
    }
    window.addEventListener('open-waitlist', open)
    return () => window.removeEventListener('open-waitlist', open)
  }, [])

  return (
    <dialog
      ref={ref}
      onClick={(e) => e.target === ref.current && ref.current?.close()}
      className="paper m-auto w-[min(calc(100vw-2.5rem),560px)] rounded-xl border border-ink p-0 text-ink shadow-[5px_5px_0_#3d1689] backdrop:bg-ink/60 sm:shadow-[8px_8px_0_#3d1689]"
    >
      <div className="relative flex flex-col gap-5 p-6 pt-8 sm:gap-6 sm:p-10">
        <button
          onClick={() => ref.current?.close()}
          aria-label="Close"
          className="absolute top-4 right-4 grid size-10 place-items-center rounded-md text-ink/60 hover:bg-ink/5 hover:text-ink"
        >
          <X className="size-5" />
        </button>
        <h2 className="display pr-10 text-[clamp(38px,6vw,56px)]">Get early access.</h2>
        <WaitlistForm key={key} autoFocus />
      </div>
    </dialog>
  )
}
