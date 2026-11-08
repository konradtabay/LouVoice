import Dither from '@/components/Dither'
import ProgressChart from '@/components/ProgressChart'
import { Cards, PageHero, Rows, Section } from '@/components/site'

export default function Caregivers() {
  return (
    <>
      <PageHero
        title="Built for them. Easier with you."
        intro={<p>You set it up, fix mistakes and plan ahead.</p>}
        art={
          <Dither
            ditherMode="halftone"
            palette={['#e6ddd6', '#a37cf0', '#682bd7', '#010101']}
            pixelSize={2}
            waveSpeed={0.03}
            scale={0.8}
            enableMouseInteraction={false}
          />
        }
      />

      <Section title="What you do">
        <Cards
          cols={4}
          items={[
            { title: 'Set it up', body: 'The app guides you.' },
            { title: 'Turn listening on or off', body: 'So it only speaks when it should.' },
            { title: 'Fix a word', body: 'Tap the right guess.' },
            { title: 'Get warnings', body: 'When movement gets too weak to read.' },
          ]}
        />
      </Section>

      <Section title="Plan ahead">
        <Rows
          items={[
            { title: 'Start early', body: 'It learns best while movement is strong.' },
            { title: 'Save the voice', body: 'Record it during training, or rebuild it from old videos and voicemails.' },
            { title: 'Keep the voice', body: 'It stays with the family after LouVoice stops working.' },
          ]}
        />
      </Section>

      <ProgressChart />
    </>
  )
}
