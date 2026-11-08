import FaceFX, { DEFAULT_FACE } from '@/components/FaceFX'
import { Cards, PageHero, Quote, Rows, Section, WRAP } from '@/components/site'

export default function Purpose() {
  return (
    <>
      <PageHero
        title="ALS takes the voice. Not the mind."
        intro={<p>Thinking usually stays sharp while speech fades. LouVoice keeps people with ALS in the conversation, in their own voice.</p>}
        art={<FaceFX src="/face-source.png" settings={DEFAULT_FACE} className="absolute top-[8%] left-[6%] w-[min(26vw,440px)]" />}
      />

      <section className={`grid gap-12 py-20 lg:grid-cols-2 lg:py-28 ${WRAP}`}>
        <Quote cite="Beukelman, Fager & Nordness, Neurology Research International, 2011">
          80 to 95% of people with ALS eventually can’t meet their daily communication needs with natural speech.
        </Quote>
        <Quote cite="ER and ICU physician">
          “The most difficult patients to treat in the ER, the ICU… are patients who come in non verbal.”
        </Quote>
      </section>

      <Section title="Why current tools fail">
        <Cards
          items={[
            { label: 'Eye-tracking', title: '5+ minutes a sentence', body: 'By the time the sentence is done, the conversation has moved on.' },
            {
              label: 'Assistive devices',
              title: 'Often left unused',
              body: 'Using a bulky device means admitting the diagnosis. ALS community services told us this is a major, recurring barrier.',
            },
            {
              label: 'Voice clone + typing',
              title: 'Your voice, typed',
              body: 'The ElevenLabs Impact Program clones voices for free, but you still type every reply.',
            },
          ]}
        />
      </Section>

      <Section title="What LouVoice changes">
        <Rows
          items={[
            { title: 'Real time', body: 'Mouth a word, hear it in your voice. No typing, no eye-tracking.' },
            { title: 'Looks normal', body: 'It’s just AirPods. Nothing to explain, so people actually use it.' },
            {
              title: 'No new device',
              body: 'ALS costs about $157,000 a year per person (ALS Canada, 2026). LouVoice doesn’t cut that, but it doesn’t add a specialist device on top either.',
            },
            { title: 'The voice stays', body: 'When LouVoice can no longer read someone, their cloned voice stays with their family.' },
          ]}
        />
      </Section>

      <Section title="What experts told us">
        <div className="grid gap-12 py-10 lg:grid-cols-2">
          <Quote cite="ALS Canada representatives, on the concept">“Absolutely fantastic.” “Incredibly thoughtful.”</Quote>
          <Quote cite="ALS Canada representatives, on deterioration tracking">
            Recalibrating over time produces a curve of how the disease is progressing.
          </Quote>
        </div>
      </Section>

      <Section title="Next">
        <Rows
          items={[
            { title: 'Pilot', body: 'We’re exploring a first pilot with a person living with ALS and their family.' },
            { title: 'Clinics', body: 'ALS Canada has offered to connect us with ALS clinics across Canada.' },
            { title: 'Open source', body: 'Publish the code so clinics and the community can use and adapt it for free.' },
            { title: 'Phone app', body: 'LouVoice runs on a Mac today. iPhone and Android come next.' },
            { title: 'Beyond ALS', body: 'Other non-verbal patients, like stroke and ER or ICU admissions, where facial movement remains.' },
          ]}
        />
      </Section>
    </>
  )
}
