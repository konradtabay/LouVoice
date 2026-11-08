import { useEffect, useRef } from 'react'

/**
 * Three scrolling motion-signal traces (like the app's sensor graph: quiet
 * baseline, then bursts that clip at the edges), drawn through a dither
 * screen in the site palette. Every look parameter is live-tunable.
 */

export const SIGNAL_STYLES = ['Lines', 'Bayer', 'Halftone', 'Crosshatch', 'Solid'] as const
export const SIGNAL_SCHEMES = ['Dark', 'Light', 'Mono', 'Ink on pearl'] as const

export type SignalSettings = {
  style: number // SIGNAL_STYLES index
  scheme: number // SIGNAL_SCHEMES index
  speed: number // 0..1
  amplitude: number // 0..2
  zoom: number // waves across the panel, 0.5..5
  bursts: number // 0..1 share of slots that fire
  thickness: number // 0.005..0.06
  spread: number // 0..0.2 vertical offset between channels
  background: number // 0..1 stripe density
}

export const DEFAULT_SIGNAL: SignalSettings = {
  style: 0,
  scheme: 3,
  speed: 0.19,
  amplitude: 0.55,
  zoom: 2.4,
  bursts: 0.75,
  thickness: 0.011,
  spread: 0.05,
  background: 0,
}

// [bg, stripe, trace3, trace2, lead]
const SCHEMES: string[][] = [
  ['#e6ddd6', '#682bd7', '#bd2e95', '#5b3629', '#010101'],
  ['#e6ddd6', '#682bd7', '#bd2e95', '#a37cf0', '#e6ddd6'],
  ['#e6ddd6', '#682bd7', '#a37cf0', '#a37cf0', '#010101'],
  ['#e6ddd6', '#918983', '#bd2e95', '#682bd7', '#010101'],
]

const VERT = `#version 300 es
in vec2 aPos;
void main(){ gl_Position = vec4(aPos, 0.0, 1.0); }`

const FRAG = `#version 300 es
precision highp float;
uniform vec2 uRes;
uniform float uTime;
uniform float uCell;
uniform int uStyle;
uniform float uAmp;
uniform float uZoom;
uniform float uBursts;
uniform float uThick;
uniform float uSpread;
uniform float uFill;
uniform vec3 uBg;
uniform vec3 uC0;
uniform vec3 uC1;
uniform vec3 uC2;
uniform vec3 uC3;
out vec4 outColor;

float h1(float n){ return fract(sin(n * 127.1) * 43758.5453); }
float vnoise(float x){ float i = floor(x), f = fract(x); return mix(h1(i), h1(i + 1.0), f * f * (3.0 - 2.0 * f)); }

float sig(float x, float ch){
  float y = (vnoise(x * 3.0 + ch * 17.0) - 0.5) * 0.05;
  float k = floor(x / 0.8);
  for (float j = -1.0; j <= 1.0; j++) {
    float id = k + j;
    float c = (id + 0.25 + 0.5 * h1(id)) * 0.8;
    float on = step(1.0 - uBursts, h1(id + 9.1));
    float w = 0.10 + 0.12 * h1(id + 3.3);
    float amp = (0.18 + 0.38 * h1(id * 1.7 + ch * 5.0)) * on * uAmp;
    float f = 16.0 + 10.0 * h1(id + ch * 2.0);
    float ph = ch * 1.9 + h1(id) * 6.28;
    float d = x - c;
    y += amp * exp(-d * d / (w * w)) * sin(d * f + ph);
  }
  return clamp(y + (ch - 1.0) * uSpread, -0.46, 0.46);
}

float trace(vec2 uv, float x, float ch){
  float y = sig(x, ch);
  float e = 0.002;
  // slope per screen unit (x advances uZoom per unit of uv.x)
  float dy = (sig(x + e, ch) - sig(x - e, ch)) / (2.0 * e) * uZoom;
  float d = abs(uv.y - y) / sqrt(1.0 + dy * dy);
  return 1.0 - smoothstep(uThick * 0.5, uThick, d);
}

const float bayer4[16] = float[16](0.,8.,2.,10.,12.,4.,14.,6.,3.,11.,1.,9.,15.,7.,13.,5.);

float threshold(vec2 cell){
  if (uStyle == 0) return abs(fract(cell.y / 4.0) - 0.5) * 2.0;
  if (uStyle == 1) { ivec2 b = ivec2(mod(cell, 4.0)); return (bayer4[b.y * 4 + b.x] + 0.5) / 16.0; }
  if (uStyle == 2) {
    vec2 r = vec2(cell.x + cell.y, cell.x - cell.y) * 0.70710678 / 4.0;
    return clamp(length(fract(r) - 0.5) * 1.41421356, 0.0, 0.999);
  }
  if (uStyle == 3) {
    float a = abs(fract((cell.x + cell.y) / 6.0) - 0.5) * 2.0;
    float b = abs(fract((cell.x - cell.y) / 6.0) - 0.5) * 2.0;
    return min(a, b) * 0.999;
  }
  return 0.5;
}

void main(){
  vec2 cell = floor(gl_FragCoord.xy / uCell);
  vec2 p = (cell + 0.5) * uCell;
  vec2 uv = vec2(p.x / uRes.y, p.y / uRes.y - 0.5);
  float x = uv.x * uZoom + uTime;

  float a = trace(uv, x, 0.0);
  float b = trace(uv, x, 1.0);
  float c = trace(uv, x, 2.0);
  float base = 1.0 - smoothstep(0.0, 0.006, abs(uv.y));

  float thr = threshold(cell);
  vec3 col = mix(uBg, uC0, step(thr, uFill));
  col = mix(col, uBg, step(thr, base * 0.9) * 0.6);
  // traces are drawn solid-ish: dither only their soft edge
  col = mix(col, uC1, step(thr * 0.35, c));
  col = mix(col, uC2, step(thr * 0.35, b));
  col = mix(col, uC3, step(thr * 0.35, a));
  outColor = vec4(col, 1.0);
}`

const hex = (h: string) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)

export default function SignalDither({
  className = '',
  pixelSize = 2,
  settings = DEFAULT_SIGNAL,
}: {
  className?: string
  pixelSize?: number
  settings?: SignalSettings
}) {
  const wrapRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const settingsRef = useRef(settings)
  settingsRef.current = settings

  useEffect(() => {
    const wrap = wrapRef.current!
    const canvas = canvasRef.current!
    const gl = canvas.getContext('webgl2', { antialias: false })
    if (!gl) return
    const sh = (type: number, src: string) => {
      const s = gl.createShader(type)!
      gl.shaderSource(s, src)
      gl.compileShader(s)
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) console.error(gl.getShaderInfoLog(s))
      return s
    }
    const prog = gl.createProgram()!
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT))
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG))
    gl.bindAttribLocation(prog, 0, 'aPos')
    gl.linkProgram(prog)
    gl.useProgram(prog)
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer())
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW)
    gl.enableVertexAttribArray(0)
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0)
    const u = (n: string) => gl.getUniformLocation(prog, n)
    const U = {
      res: u('uRes'), time: u('uTime'), cell: u('uCell'), style: u('uStyle'), amp: u('uAmp'), zoom: u('uZoom'),
      bursts: u('uBursts'), thick: u('uThick'), spread: u('uSpread'), fill: u('uFill'),
      bg: u('uBg'), c0: u('uC0'), c1: u('uC1'), c2: u('uC2'), c3: u('uC3'),
    }

    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    let raf = 0
    let visible = true
    let last = 0
    let phase = 4
    let ratio = 1
    const draw = (now: number) => {
      raf = 0
      if (!visible || document.hidden) return
      const s = settingsRef.current
      const dt = last ? Math.min((now - last) / 1000, 0.05) : 0
      last = now
      if (!reduce) phase += dt * s.speed // integrate so speed changes don't jump
      const pal = SCHEMES[s.scheme] ?? SCHEMES[0]
      gl.viewport(0, 0, canvas.width, canvas.height)
      gl.uniform2f(U.res, canvas.width, canvas.height)
      gl.uniform1f(U.cell, Math.max(1, Math.round(pixelSize * ratio)))
      gl.uniform1f(U.time, phase)
      gl.uniform1i(U.style, s.style)
      gl.uniform1f(U.amp, s.amplitude)
      gl.uniform1f(U.zoom, s.zoom)
      gl.uniform1f(U.bursts, s.bursts)
      gl.uniform1f(U.thick, s.thickness)
      gl.uniform1f(U.spread, s.spread)
      gl.uniform1f(U.fill, s.background)
      ;[U.bg, U.c0, U.c1, U.c2, U.c3].forEach((loc, i) => gl.uniform3fv(loc, hex(pal[i])))
      gl.drawArrays(gl.TRIANGLES, 0, 3)
      raf = requestAnimationFrame(draw)
    }
    const wake = () => {
      if (!raf) {
        last = 0
        raf = requestAnimationFrame(draw)
      }
    }
    const resize = () => {
      ratio = Math.min(window.devicePixelRatio || 1, 2)
      canvas.width = Math.max(1, Math.round(wrap.clientWidth * ratio))
      canvas.height = Math.max(1, Math.round(wrap.clientHeight * ratio))
      wake()
    }
    const ro = new ResizeObserver(resize)
    ro.observe(wrap)
    const io = new IntersectionObserver((es) => {
      visible = es.some((e) => e.isIntersecting)
      if (visible) wake()
    })
    io.observe(wrap)
    document.addEventListener('visibilitychange', wake)
    resize()
    return () => {
      cancelAnimationFrame(raf)
      ro.disconnect()
      io.disconnect()
      document.removeEventListener('visibilitychange', wake)
    }
  }, [pixelSize])

  return (
    <div ref={wrapRef} className={`relative h-full w-full ${className}`}>
      <canvas ref={canvasRef} aria-hidden className="absolute inset-0 h-full w-full" />
    </div>
  )
}
