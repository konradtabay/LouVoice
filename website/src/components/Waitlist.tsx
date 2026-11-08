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
  const [error, setError] = useState(false)
  const [done, setDone] = useState(false)

  function submit(e: FormEvent) {
    e.preventDefault()
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) return setError(true)
    // TODO: send the email to the waitlist backend. Nothing is stored yet.
    setDone(true)
  }

  if (done)
    return (
      <p role="status" className={`flex items-center gap-3 text-[18px] font-semibold ${dark ? 'text-pearl' : 'text-ink'}`}>
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
          aria-invalid={error}
          placeholder="you@email.com"
          value={email}
          onChange={(e) => { setEmail(e.target.value); setError(false) }}
          className={`h-16 min-w-0 flex-1 rounded-lg border px-5 text-[18px] outline-none transition focus:ring-2 ${
            dark
              ? 'border-pearl/60 bg-ink/40 text-pearl placeholder:text-pearl/50 focus:border-pearl focus:ring-portage/50'
              : 'border-ink bg-pearl text-ink placeholder:text-ink/40 focus:border-[#3d1689] focus:ring-[#3d1689]/30'
          }`}
        />
        <button
          type="submit"
          className={`inline-flex h-16 shrink-0 items-center justify-center gap-3 rounded-lg px-8 text-[18px] font-semibold transition active:translate-y-px ${
            dark ? 'bg-pearl text-ink hover:bg-portage' : 'bg-ink text-pearl shadow-[5px_5px_0_#682bd7] hover:bg-[#3d1689]'
          }`}
        >
          Join the waitlist <ArrowRight className="size-5" />
        </button>
      </div>
      {error && <p className={`text-[14px] font-semibold ${dark ? 'text-portage' : 'text-[#bd2e95]'}`}>Enter a valid email.</p>}
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
      className="paper m-auto w-[min(92vw,560px)] rounded-xl border border-ink p-0 text-ink shadow-[8px_8px_0_#3d1689] backdrop:bg-ink/60"
    >
      <div className="relative flex flex-col gap-6 p-8 sm:p-10">
        <button
          onClick={() => ref.current?.close()}
          aria-label="Close"
          className="absolute top-4 right-4 grid size-10 place-items-center rounded-md text-ink/60 hover:bg-ink/5 hover:text-ink"
        >
          <X className="size-5" />
        </button>
        <h2 className="display text-[clamp(40px,6vw,56px)]">Get early access.</h2>
        <WaitlistForm key={key} autoFocus />
      </div>
    </dialog>
  )
}
