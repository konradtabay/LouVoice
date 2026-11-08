/**
 * Graphics for the three "How it works" cards, drawn as engraved line art
 * on the same horizontal line-screen the hero uses.
 * Viewbox is 400×224 to match the card header (h-56).
 */

const INK = '#010101'
const PEARL = '#e6ddd6'
const SCHOONER = '#918983'
const HEART = '#682bd7'
const PORTAGE = '#a37cf0'
const VIOLET = '#bd2e95'

function Defs({ id }: { id: string }) {
  return (
    <defs>
      {/* page line-screen */}
      <pattern id={`${id}-screen`} width="6" height="4" patternUnits="userSpaceOnUse">
        <rect width="6" height="1.2" fill={SCHOONER} opacity="0.35" />
      </pattern>
      {/* engraved shading: dense ink lines on schooner */}
      <pattern id={`${id}-engrave`} width="6" height="3.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-18)">
        <rect width="6" height="3.2" fill={SCHOONER} />
        <rect width="6" height="1.5" fill={INK} />
      </pattern>
      <pattern id={`${id}-engrave-dark`} width="6" height="3" patternUnits="userSpaceOnUse" patternTransform="rotate(-18)">
        <rect width="6" height="3" fill={SCHOONER} />
        <rect width="6" height="2.1" fill={INK} />
      </pattern>
    </defs>
  )
}

function Frame({ id, children, label }: { id: string; children: React.ReactNode; label: string }) {
  return (
    <svg viewBox="0 0 400 224" preserveAspectRatio="xMidYMid meet" className="step-graphic block h-full w-full" role="img" aria-label={label}>
      <Defs id={id} />
      {/* backgrounds run past the viewBox so wide cards stay filled */}
      <rect x="-400" y="-200" width="1200" height="624" fill={PEARL} />
      <rect x="-400" y="-200" width="1200" height="624" fill={`url(#${id}-screen)`} />
      {children}
    </svg>
  )
}

/* 01 · Teach — a hand holding an index card of words */
export function TeachGraphic() {
  const id = 'teach'
  const words: [string, boolean][] = [
    ['I love you', true],
    ['Maya', true],
    ['How was your day', false],
    ['Water', false],
  ]
  return (
    <Frame id={id} label="A hand holding an index card listing words to teach">
      {/* palm + fingers behind the card */}
      <path
        d="M-10 236 C10 206 40 186 82 178 L150 170 C166 169 172 185 158 191 L136 197 C154 200 155 216 138 218 L112 221 C122 226 118 238 104 238 Z"
        fill={`url(#${id}-engrave-dark)`} stroke={INK} strokeWidth="2" strokeLinejoin="round"
      />
      {/* fingertips curling up behind the card */}
      <g transform="rotate(-6 228 104)">
        {[176, 204, 232].map((x, i) => (
          <rect key={x} x={x} y={150} width="25" height={68 - i * 5} rx="12.5"
            fill={`url(#${id}-engrave-dark)`} stroke={INK} strokeWidth="2" />
        ))}
      </g>
      <g transform="rotate(-6 228 104)">
        <rect x="112" y="24" width="236" height="156" fill={PEARL} stroke={INK} strokeWidth="2" />
        <line x1="112" y1="52" x2="348" y2="52" stroke={VIOLET} strokeWidth="1.5" />
        {[0, 1, 2, 3].map((i) => (
          <line key={i} x1="112" y1={84 + i * 28} x2="348" y2={84 + i * 28} stroke={PORTAGE} strokeWidth="1" opacity="0.7" />
        ))}
        <text x="126" y="44" fontFamily="'Geist Mono', ui-monospace, monospace" fontSize="10" fill={INK} opacity="0.6" letterSpacing="1">MY WORDS</text>
        {words.map(([w, done], i) => (
          <g key={w}>
            <text x="126" y={78 + i * 28} fontFamily="'Geist Serif Square', serif" fontSize="19" fill={INK}>{w}</text>
            {done ? (
              <path d={`M318 ${70 + i * 28} l5 5 l10 -11`} fill="none" stroke={HEART} strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
            ) : (
              <text x="312" y={78 + i * 28} fontFamily="'Geist Mono', ui-monospace, monospace" fontSize="10" fill={INK} opacity="0.45">×3</text>
            )}
          </g>
        ))}
      </g>
      {/* thumb in front of the card */}
      <g transform="translate(-6 22)">
      <path
        d="M70 196 C82 178 108 166 136 160 C150 157 158 168 150 176 C136 186 112 194 94 204 Z"
        fill={`url(#${id}-engrave)`} stroke={INK} strokeWidth="2" strokeLinejoin="round"
      />
      <path d="M134 163 C141 162 146 166 145 171" fill="none" stroke={INK} strokeWidth="1.5" />
      </g>
    </Frame>
  )
}

/* 02 · Mouth it — the live signal snapping onto the taught pattern */
function burst(amp: number, phase: number, k: number) {
  const pts: string[] = []
  for (let x = -200; x <= 600; x += 3) {
    const d = (x - 205) / 70
    const y = 112 - amp * Math.exp(-d * d) * Math.sin(d * k + phase) + 2 * Math.sin(x * 0.07 + phase)
    pts.push(`${x},${y.toFixed(1)}`)
  }
  return `M${pts.join(' L')}`
}

export function MatchGraphic() {
  const id = 'match'
  return (
    <Frame id={id} label="A live jaw-motion signal matching a taught pattern, match 0.94">
      <line x1="-400" y1="112" x2="800" y2="112" stroke={SCHOONER} strokeWidth="1" />
      {/* taught pattern */}
      <path d={burst(70, 0.2, 6.2)} fill="none" stroke={HEART} strokeWidth="2.5" strokeDasharray="6 6" />
      {/* live trace, drawn in */}
      <path d={burst(66, 0.35, 6.0)} pathLength={1} className="match-trace" fill="none" stroke={INK} strokeWidth="3.5" strokeLinejoin="round" />
      {/* tag */}
      <g transform="translate(250 30)">
        <rect width="118" height="30" fill={PEARL} stroke={INK} strokeWidth="1.5" />
        <circle cx="16" cy="15" r="4.5" fill={VIOLET} />
        <text x="28" y="20" fontFamily="'Geist Mono', ui-monospace, monospace" fontSize="13" fill={INK}>match 0.94</text>
      </g>
      <text x="20" y="206" fontFamily="'Geist Mono', ui-monospace, monospace" fontSize="10" letterSpacing="1" fill={INK} opacity="0.55">
        — LIVE    - - TAUGHT · “I LOVE YOU”
      </text>
    </Frame>
  )
}

/* 03 · Hear it — speaker grille with sound coming out */
export function SpeakGraphic() {
  const id = 'speak'
  const cx = 138
  const cy = 112
  const R = 80
  const holes: { x: number; y: number; r: number }[] = []
  for (let row = -12; row <= 12; row++) {
    for (let col = -12; col <= 12; col++) {
      const x = cx + col * 7 + (row % 2 ? 3.5 : 0)
      const y = cy + row * 6.1
      const d = Math.hypot(x - cx, y - cy)
      if (d > R - 9) continue
      // engraved light: holes open wider toward the upper left
      const light = 1 - Math.hypot(x - (cx - 30), y - (cy - 30)) / (R * 1.9)
      holes.push({ x, y, r: 0.9 + 2.0 * Math.max(0, light) })
    }
  }
  return (
    <Frame id={id} label="A speaker grille with sound waves saying “I love you”">
      <circle cx={cx} cy={cy} r={R + 8} fill={`url(#${id}-engrave)`} stroke={INK} strokeWidth="2" />
      <circle cx={cx} cy={cy} r={R} fill={INK} stroke={INK} strokeWidth="2" />
      {holes.map((h, i) => (
        <circle key={i} cx={h.x} cy={h.y} r={h.r} fill={SCHOONER} />
      ))}
      {[0, 1, 2, 3].map((i) => (
        <path
          key={i}
          className="speak-arc"
          style={{ animationDelay: `${i * 0.35}s` }}
          d={`M${cx + R + 22 + i * 26} ${cy - 46 - i * 12} A ${60 + i * 26} ${60 + i * 26} 0 0 1 ${cx + R + 22 + i * 26} ${cy + 46 + i * 12}`}
          fill="none"
          stroke={i % 2 ? HEART : VIOLET}
          strokeWidth={3.2 - i * 0.5}
          strokeLinecap="round"
        />
      ))}
      <text x="392" y="210" textAnchor="end" fontFamily="'Geist Serif Square', serif" fontSize="22" fill={INK}>“I love you”</text>
    </Frame>
  )
}
