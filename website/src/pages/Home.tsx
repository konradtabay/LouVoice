import { ArrowRight } from 'lucide-react'
import Dither from '@/components/Dither'
import SignalDither, { DEFAULT_SIGNAL, type SignalSettings } from '@/components/SignalDither'
import FaceFX, { DEFAULT_FACE, type FaceSettings } from '@/components/FaceFX'
import { Button } from '@/components/ui/button'
import { MatchGraphic, SpeakGraphic, TeachGraphic } from '@/components/StepGraphics'
import { Link } from '@/router'
import { openWaitlist } from '@/components/Waitlist'

function Badge({ className = '' }: { className?: string }) {
  return (
    <div className={`flex flex-col items-center justify-center rounded-full bg-pearl shadow-[0_0_0_1px_rgb(1_1_1/0.08)] ${className}`}>
      <b className="display text-[52px] leading-none">10<span className="text-[0.5em]">min</span></b>
      <span className="mt-1 text-[12.5px] text-ink/75">first training</span>
    </div>
  )
}

function Hero({ face, signal }: { face: FaceSettings; signal: SignalSettings }) {
  return (
    <section className="relative overflow-hidden">
      {/* ——— right-hand art ——— */}
      <div aria-hidden className="pointer-events-none absolute inset-0 hidden lg:block">
        <div className="grid-lines absolute top-0 bottom-0 left-[42%] right-0" />
        <div className="absolute top-0 right-0 left-[57.5%] h-[47%] overflow-hidden">
          <SignalDither settings={signal} />
        </div>
        <div className="absolute right-0 bottom-0 h-[30%] w-[17%] overflow-hidden border-t border-l border-ink/30">
          <Dither
            ditherMode="crosshatch"
            palette={['#010101', '#5b3629', '#a37cf0', '#e6ddd6']}
            pixelSize={2}
            waveSpeed={0.04}
            scale={0.7}
            enableMouseInteraction={false}
          />
        </div>
        <div className="hatch absolute bottom-0 left-0 h-[13%] w-[48%] [clip-path:polygon(0_0,82%_0,100%_100%,0_100%)]" />
        <span className="absolute top-[46%] left-[75%] size-2.5 rounded-full bg-violet" />
        <span className="absolute bottom-[12.6%] left-[46.6%] size-2.5 rounded-full bg-violet" />
      </div>

      {/* face */}
      <div className="pointer-events-none absolute top-[15%] left-[52%] hidden w-[min(34vw,620px)] lg:block">
        <FaceFX src="/face-source.png" settings={face} />
        <Badge className="absolute -right-[10%] bottom-[14%] size-[150px]" />
      </div>

      {/* ——— copy ——— */}
      <div className="relative z-10 mx-auto max-w-[1680px] px-5 pt-14 pb-10 sm:px-8 lg:min-h-[1020px] lg:pt-28 xl:w-[calc(100%-4rem)] xl:px-0">
        <h1 className="display text-[clamp(48px,6.2vw,100px)]">
          <span className="block">Mouth a word.</span>
          <span className="block">Your voice speaks.</span>
        </h1>
        <p className="mt-10 max-w-[34rem] text-[19px] leading-[1.65] text-ink/85 sm:text-[21px]">
          LouVoice feels your jaw muscles move through your AirPods and turns each silent word into text, spoken in your
          own voice. No camera, no microphone. Built for people with ALS.
        </p>
        <div className="mt-12 flex flex-wrap items-center gap-6">
          <Button onClick={openWaitlist} className="h-16 gap-3 bg-ink px-8 text-[18px] font-semibold text-pearl shadow-[5px_5px_0_#682bd7] hover:bg-[#3d1689]">
            Join the waitlist <ArrowRight className="size-5" />
          </Button>
          <Link to="/#how" className="hatch-underline text-[17px] font-semibold">
            How LouVoice reads a word
          </Link>
        </div>

        {/* mobile art */}
        <div className="relative mt-14 lg:hidden">
          <div className="absolute inset-x-0 top-0 h-1/2 overflow-hidden">
            <SignalDither settings={signal} />
          </div>
          <FaceFX src="/face-source.png" settings={face} className="mx-auto mt-10 max-w-[380px]" />
          <Badge className="absolute right-0 -bottom-6 size-[110px] [&_b]:text-[38px]" />
        </div>
      </div>
    </section>
  )
}

const WORDS = ['I love you', 'How was your day', 'Water', 'Yes', 'No', 'Thank you', 'Come here', 'Goodnight', 'Maya', "I'm tired", 'Turn it up', 'Help']

function Marquee() {
  return (
    <div className="overflow-hidden border-y border-ink bg-ink py-5 text-pearl">
      <div className="marquee flex w-max gap-12 whitespace-nowrap">
        {[...WORDS, ...WORDS].map((l, i) => (
          <span key={i} className="display flex items-center gap-12 text-[34px] leading-none">
            {l} <span className="size-2 rounded-full bg-portage" />
          </span>
        ))}
      </div>
    </div>
  )
}

const STEPS = [
  {
    n: '01',
    title: 'Train',
    body: 'Pick the words that matter most: “I love you,” your kids’ names. Mouth each a few times. A first round takes about 10 minutes.',
    Graphic: TeachGraphic,
  },
  {
    n: '02',
    title: 'Mouth it',
    body: 'Press the AirPods stem and mouth a word, silently. Their motion sensors feel your jaw muscles move, and LouVoice turns that pattern into text.',
    Graphic: MatchGraphic,
  },
  {
    n: '03',
    title: 'Hear it',
    body: 'The word appears on screen and plays in your cloned voice.',
    Graphic: SpeakGraphic,
  },
]

function HowItWorks() {
  return (
    <section id="how" className="mx-auto max-w-[1680px] px-5 py-24 sm:px-8 lg:py-32 xl:w-[calc(100%-4rem)] xl:px-0">
      <div className="flex flex-wrap items-end justify-between gap-6 border-b border-ink pb-8">
        <h2 className="display max-w-[14ch] text-[clamp(48px,6.4vw,96px)]">From muscle to voice</h2>
        <p className="max-w-md text-[18px] leading-relaxed text-ink/75">
          Three steps, AirPods Pro and a Mac. No special medical hardware.
        </p>
      </div>
      <div className="grid gap-px bg-ink md:grid-cols-3">
        {STEPS.map(({ n, title, body, Graphic }) => (
          <article key={n} className="paper flex flex-col">
            <div className="relative h-56 overflow-hidden border-b border-ink">
              <Graphic />
              <span className="absolute top-4 left-4 bg-pearl px-2 py-1 font-mono text-[13px]">{n}</span>
            </div>
            <div className="flex flex-1 flex-col gap-4 p-8">
              <h3 className="display text-[44px]">{title}</h3>
              <p className="text-[17px] leading-relaxed text-ink/75">{body}</p>
            </div>
          </article>
        ))}
      </div>
    </section>
  )
}

function Stats() {
  const stats = [
    ['80–95%', 'of people with ALS lose usable speech'],
    ['0', 'cameras or microphones. Only muscle motion'],
    ['10 min', 'to your first words'],
    ['95%+', 'word accuracy'],
  ]
  return (
    <section id="stats" className="mx-auto grid max-w-[1680px] grid-cols-2 border-y border-ink lg:grid-cols-4 xl:w-[calc(100%-4rem)]">
      {stats.map(([v, l], i) => (
        <div key={v} className={`border-ink p-6 sm:p-10 ${i % 2 ? '' : 'border-r'} ${i < 2 ? 'border-b lg:border-b-0' : ''} lg:border-r lg:last:border-r-0`}>
          <div className="display text-[clamp(44px,5vw,80px)] text-[#3d1689]" style={{ fontWeight: 800 }}>{v}</div>
          <div className="mt-3 max-w-[24ch] text-[15px] font-semibold text-[#3d1689]">{l}</div>
        </div>
      ))}
    </section>
  )
}

export default function Home() {
  return (
    <>
      <Hero face={DEFAULT_FACE} signal={DEFAULT_SIGNAL} />
      <Marquee />
      <HowItWorks />
      <Stats />
      <div className="h-24" />
    </>
  )
}
