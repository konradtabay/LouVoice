import { useEffect, useState, type AnchorHTMLAttributes, type MouseEvent } from 'react'

/** Minimal path router: History API + popstate. No dependency needed for five pages. */

const listeners = new Set<() => void>()

export function navigate(to: string) {
  const url = new URL(to, window.location.href)
  if (url.pathname === window.location.pathname && url.hash) {
    window.history.pushState(null, '', url.pathname + url.hash)
    document.querySelector(url.hash)?.scrollIntoView({ behavior: 'smooth' })
    return
  }
  window.history.pushState(null, '', url.pathname + url.hash)
  listeners.forEach((l) => l())
  if (url.hash) requestAnimationFrame(() => document.querySelector(url.hash)?.scrollIntoView())
  else window.scrollTo(0, 0)
}

export function usePath() {
  const [path, setPath] = useState(window.location.pathname)
  useEffect(() => {
    const update = () => setPath(window.location.pathname)
    listeners.add(update)
    window.addEventListener('popstate', update)
    return () => {
      listeners.delete(update)
      window.removeEventListener('popstate', update)
    }
  }, [])
  return path
}

export function Link({ to, onClick, ...rest }: { to: string } & AnchorHTMLAttributes<HTMLAnchorElement>) {
  const handle = (e: MouseEvent<HTMLAnchorElement>) => {
    onClick?.(e)
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
    e.preventDefault()
    navigate(to)
  }
  return <a href={to} onClick={handle} {...rest} />
}
