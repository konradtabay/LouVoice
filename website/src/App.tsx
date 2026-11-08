import { useEffect, useState } from 'react'
import { ClosingCTA, FloatingWaitlist, Header, PageHero } from '@/components/site'
import { WaitlistPopup } from '@/components/Waitlist'
import Caregivers from '@/pages/Caregivers'
import Home from '@/pages/Home'
import Purpose from '@/pages/Purpose'
import { Link, usePath } from '@/router'

const ROUTES: Record<string, { title: string; Page: () => React.JSX.Element }> = {
  '/': { title: 'LouVoice — mouth a word, your voice speaks', Page: Home },
  '/purpose': { title: 'Purpose — LouVoice', Page: Purpose },
  '/caregivers': { title: 'For caregivers — LouVoice', Page: Caregivers },
}

function NotFound() {
  return (
    <PageHero
      title="That page doesn’t exist."
      intro={
        <p>
          <Link to="/" className="hatch-underline font-semibold">
            Back to LouVoice
          </Link>
        </p>
      }
    />
  )
}

export default function App() {
  const path = usePath().replace(/\/+$/, '') || '/'
  const route = ROUTES[path]
  const Page = route?.Page ?? NotFound

  useEffect(() => {
    document.title = route?.title ?? 'Not found — LouVoice'
  }, [route])

  // The floating waitlist button appears once the page's first section (its hero) has scrolled away.
  const [pastHero, setPastHero] = useState(false)
  useEffect(() => {
    setPastHero(false)
    const el = document.querySelector('main > section')
    if (!el) return
    const io = new IntersectionObserver(([e]) => setPastHero(!e.isIntersecting && e.boundingClientRect.top < 0))
    io.observe(el)
    return () => io.disconnect()
  }, [path])

  return (
    <div className="paper min-h-screen overflow-x-hidden text-ink">
      <Header />
      <FloatingWaitlist show={pastHero} />
      <main>
        <Page />
      </main>
      <ClosingCTA />
      <WaitlistPopup />
    </div>
  )
}
