import { useEffect, useRef, useState } from 'react'

export const EFFECTS = ['Lines', 'Rings', 'Halftone', 'Crosshatch', 'Dither', 'Stipple'] as const

export type FaceSettings = {
  effect: number // index into EFFECTS
  intensity: number // 0..2 distortion
  opacity: number // 0..1
  crop: number // 0..0.5 fraction of height faded from the top
}

export const DEFAULT_FACE: FaceSettings = { effect: 3, intensity: 0, opacity: 1, crop: 0.46 }

const VERT = `#version 300 es
in vec2 aPos;
out vec2 vUv;
void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos, 0.0, 1.0); }`

const FRAG = `#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uTex;
uniform float uTime;
uniform vec2 uRes;
uniform int uMode;
uniform float uIntensity;
uniform float uOpacity;
uniform float uCrop;
out vec4 outColor;

vec2 hash2(vec2 p){
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453) * 2.0 - 1.0;
}
float hash1(vec2 p){ return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float noise(vec2 p){
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(dot(hash2(i), f), dot(hash2(i + vec2(1,0)), f - vec2(1,0)), u.x),
             mix(dot(hash2(i + vec2(0,1)), f - vec2(0,1)), dot(hash2(i + vec2(1,1)), f - vec2(1,1)), u.x), u.y);
}
float lum(vec3 c){ return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
float band(float f, float width){
  float s = abs(fract(f) - 0.5) * 2.0;
  float aa = fwidth(f) * 1.5;
  return 1.0 - smoothstep(width - aa, width + aa, s);
}

const float bayer4[16] = float[16](0.,8.,2.,10.,12.,4.,14.,6.,3.,11.,1.,9.,15.,7.,13.,5.);

void main(){
  vec2 uv = vec2(vUv.x, 1.0 - vUv.y);           // top-left origin
  float t = uTime * 0.18;
  vec2 drift = vec2(noise(uv * 2.6 + vec2(t, -t * 0.7)), noise(uv * 2.6 + vec2(-t * 0.8, t) + 7.3));
  vec2 fine = vec2(noise(uv * 9.0 + vec2(0.0, t * 1.6)), noise(uv * 9.0 + vec2(t * 1.4, 3.1)));
  vec2 wuv = uv + (drift * 0.012 + fine * 0.003) * (0.4 + uIntensity);
  vec2 suv = vec2(1.0 - wuv.x, wuv.y);           // mirrored: face looks left

  float Lb = lum(textureLod(uTex, suv, 1.2).rgb);
  float Lw = lum(textureLod(uTex, suv, 3.5).rgb);
  float Lm = lum(textureLod(uTex, suv, 2.5).rgb);
  float mask = smoothstep(0.015, 0.06, Lm);
  mask *= smoothstep(uCrop, uCrop + 0.14, uv.y);
  if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) mask = 0.0;
  if (mask <= 0.001) { outColor = vec4(0.0); return; }

  float T = pow(clamp((Lb - 0.04) / 0.72, 0.0, 1.0), 0.6) * 0.9 + 0.04;
  vec2 px = gl_FragCoord.xy;
  float k = uRes.y / 520.0;                      // keep line density stable across sizes
  float wob = (noise(uv * 3.0 + 4.0) * 2.2 + noise(uv * 9.0) * 0.7) * uIntensity;
  float bend = (8.0 + 6.0 * uIntensity) * Lw;

  float mark;
  if (uMode == 0) {            // Lines
    float f = (px.y + 6.0 * k * sin(px.x / (18.0 * k))) / (3.2 * k) + bend + wob;
    mark = band(f, 0.04 + 0.9 * pow(T, 1.15));
  } else if (uMode == 1) {     // Rings
    vec2 c = vec2(0.5, 0.45);
    float f = length((uv - c) * vec2(1.0, 1.25)) * 95.0 + bend * 1.2 + wob * 1.5;
    mark = band(f, 0.04 + 0.9 * pow(T, 1.15));
  } else if (uMode == 2) {     // Halftone
    vec2 q = mat2(0.7071, -0.7071, 0.7071, 0.7071) * (px / (5.0 * k) + vec2(wob, -wob) * 0.6);
    float d = length(fract(q) - 0.5);
    float r = sqrt(T) * 0.62;
    float aa = fwidth(d) * 1.2;
    mark = 1.0 - smoothstep(r - aa, r + aa, d);
  } else if (uMode == 3) {     // Crosshatch (light paper, dark hatching)
    float a = band((px.x + px.y) / (5.0 * k) + wob + bend * 0.5, 0.42);
    float b = band((px.x - px.y) / (5.0 * k) - wob + bend * 0.5, 0.42);
    float h = px.y / (3.5 * k) + wob;
    float c3 = band(h, 0.5);
    float ink = a * step(T, 0.75) + b * step(T, 0.5) + c3 * step(T, 0.28);
    mark = 1.0 - clamp(ink, 0.0, 1.0);
  } else if (uMode == 4) {     // Dither
    vec2 cell = floor((px + vec2(wob) * 4.0 * k) / (2.0 * k));
    ivec2 b = ivec2(mod(cell, 4.0));
    mark = step(bayer4[b.y * 4 + b.x] / 16.0, T);
  } else {                     // Stipple
    vec2 cell = floor((px + vec2(wob) * 3.0 * k) / (1.6 * k));
    mark = step(hash1(cell + floor(uTime * 6.0) * 0.0), T * T * 1.1);
  }

  vec3 ink = vec3(0.075, 0.068, 0.068);
  vec3 paper = vec3(0.569, 0.537, 0.514) * 0.92;
  vec3 pearl = vec3(0.902, 0.867, 0.839) * 0.85;
  vec3 light = mix(paper, pearl, clamp((T - 0.7) / 0.3, 0.0, 1.0) * 0.5);
  vec3 col = mix(ink, light, mark);
  col *= 0.9 + 0.18 * hash1(px);
  float a = mask * uOpacity;
  outColor = vec4(col * a, a);
}`

function compile(gl: WebGL2RenderingContext, type: number, src: string) {
  const s = gl.createShader(type)!
  gl.shaderSource(s, src)
  gl.compileShader(s)
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
    console.error(gl.getShaderInfoLog(s))
    return null
  }
  return s
}

/** Live-engraved face. Aspect follows the source image (216×271). */
export default function FaceFX({ src, settings, className = '' }: { src: string; settings: FaceSettings; className?: string }) {
  const wrapRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const settingsRef = useRef(settings)
  settingsRef.current = settings
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    const wrap = wrapRef.current!
    const canvas = canvasRef.current!
    const gl = canvas.getContext('webgl2', { alpha: true, premultipliedAlpha: true, antialias: false })
    const vs = gl && compile(gl, gl.VERTEX_SHADER, VERT)
    const fs = gl && compile(gl, gl.FRAGMENT_SHADER, FRAG)
    if (!gl || !vs || !fs) {
      setFailed(true)
      return
    }
    const prog = gl.createProgram()!
    gl.attachShader(prog, vs)
    gl.attachShader(prog, fs)
    gl.bindAttribLocation(prog, 0, 'aPos')
    gl.linkProgram(prog)
    gl.useProgram(prog)
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer())
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW)
    gl.enableVertexAttribArray(0)
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0)
    const u = (n: string) => gl.getUniformLocation(prog, n)
    const uTime = u('uTime'), uRes = u('uRes'), uMode = u('uMode'), uInt = u('uIntensity'), uOp = u('uOpacity'), uCrop = u('uCrop')

    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    let raf = 0
    let visible = true
    let ready = false
    let disposed = false
    const t0 = performance.now()

    const draw = () => {
      raf = 0
      if (!visible || document.hidden || !ready) return
      const s = settingsRef.current
      gl.viewport(0, 0, canvas.width, canvas.height)
      gl.clearColor(0, 0, 0, 0)
      gl.clear(gl.COLOR_BUFFER_BIT)
      gl.uniform1f(uTime, reduce ? 0 : (performance.now() - t0) / 1000)
      gl.uniform2f(uRes, canvas.width, canvas.height)
      gl.uniform1i(uMode, s.effect)
      gl.uniform1f(uInt, s.intensity)
      gl.uniform1f(uOp, s.opacity)
      gl.uniform1f(uCrop, s.crop)
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
      if (!reduce) raf = requestAnimationFrame(draw)
    }
    const wake = () => {
      if (!raf) raf = requestAnimationFrame(draw)
    }
    const resize = () => {
      const ratio = Math.min(window.devicePixelRatio || 1, 2)
      canvas.width = Math.round(wrap.clientWidth * ratio)
      canvas.height = Math.round(wrap.clientHeight * ratio)
      wake()
    }

    const img = new Image()
    img.src = src
    img.decode().then(() => {
      if (disposed) return
      gl.bindTexture(gl.TEXTURE_2D, gl.createTexture())
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img)
      gl.generateMipmap(gl.TEXTURE_2D)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
      ready = true
      wake()
    })

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
      disposed = true
      cancelAnimationFrame(raf)
      ro.disconnect()
      io.disconnect()
      document.removeEventListener('visibilitychange', wake)
    }
  }, [src])

  return (
    <div ref={wrapRef} className={`relative aspect-[216/271] ${className}`}>
      {failed ? (
        <img src="/face-engraved.webp" alt="Engraved illustration of facial anatomy" className="h-full w-full object-contain" />
      ) : (
        <canvas ref={canvasRef} role="img" aria-label="Engraved illustration of facial anatomy" className="absolute inset-0 h-full w-full" />
      )}
    </div>
  )
}
