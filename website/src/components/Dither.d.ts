import type { CSSProperties, FC } from 'react'
declare const Dither: FC<{
  waveSpeed?: number
  waveFrequency?: number
  waveAmplitude?: number
  waveColor?: [number, number, number] | string
  backgroundColor?: [number, number, number] | string
  colorNum?: number
  pixelSize?: number
  disableAnimation?: boolean
  enableMouseInteraction?: boolean
  mouseRadius?: number
  ditherMode?: 'bayer' | 'bayer4' | 'bayer2' | 'halftone' | 'lines' | 'crosshatch' | 'noise' | 'none'
  palette?: string[]
  scale?: number
  contrast?: number
  brightness?: number
  mouseEffect?: 'erase' | 'reveal' | 'ripple'
  mouseStrength?: number
  trail?: number
  clickRipple?: boolean
  intro?: boolean
  dpr?: number
  className?: string
  style?: CSSProperties
}>
export default Dither
