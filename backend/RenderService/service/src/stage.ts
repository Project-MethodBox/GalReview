// RenderService visual-novel stage (WebGPU + procedural shaders).
//
// The WASM core stays the logic authority (validation, session state,
// scoring, elapsed time); this module owns the pixels: style-driven
// procedural backgrounds, scene dissolve transitions, ambient particles and
// emotion tinting, rendered with WebGPU when available and a Canvas2D
// gradient fallback otherwise. Dialogue text stays in a DOM overlay by
// design — crisp CJK glyphs and accessibility beat texture-atlas text.
//
// Served to browsers as a single standalone ES module (dist/stage.js):
// only type-only imports are allowed here. Pure helpers are exported for
// vitest; nothing touches GPU or DOM at import time.

export type StageStyle = 'CAMPUS' | 'FANTASY' | 'SCIENCE'
export type StageBackend = 'webgpu' | 'canvas2d'

export interface StageOptions {
  canvas: HTMLCanvasElement
  style?: StageStyle
  /** Honours the user's reduced-motion preference: damps particles/sway. */
  reducedMotion?: boolean
}

export interface VisualStage {
  readonly backend: StageBackend
  /** Crossfades to a new procedural scene; the seed varies the composition. */
  showScene(sceneId: string): void
  /** Switches the style palette live (demo/style-preview use). */
  setStyle(style: StageStyle): void
  /** Tint pulse for the active speaker's emotion (null clears it). */
  setEmotion(emotion: string | null): void
  /** Advances animations; the caller owns the rAF loop (and should also
   * call adapter.renderFrame(deltaMs) to keep the WASM clock authoritative). */
  frame(deltaMs: number): void
  resize(width: number, height: number): void
  dispose(): void
}

// ---------------------------------------------------------------------------
// Pure, testable helpers
// ---------------------------------------------------------------------------

export const STYLE_INDEX: Record<StageStyle, number> = {
  CAMPUS: 0,
  FANTASY: 1,
  SCIENCE: 2,
}

export interface StylePalette {
  skyTop: [number, number, number]
  skyBottom: [number, number, number]
  accent: [number, number, number]
}

// Palettes mirrored inside the WGSL shader; exported for the 2D fallback
// and for tests that pin the style identities.
export function stylePalette(style: StageStyle): StylePalette {
  switch (style) {
    case 'FANTASY':
      return { skyTop: [0.16, 0.09, 0.32], skyBottom: [0.42, 0.16, 0.38], accent: [0.85, 0.62, 1.0] }
    case 'SCIENCE':
      return { skyTop: [0.02, 0.05, 0.12], skyBottom: [0.05, 0.14, 0.25], accent: [0.35, 0.85, 1.0] }
    default:
      return { skyTop: [0.99, 0.82, 0.65], skyBottom: [0.65, 0.78, 0.98], accent: [1.0, 0.72, 0.82] }
  }
}

// Deterministic 32-bit hash of a scene id -> [0, 1) seed that varies the
// procedural composition per scene while staying reproducible.
export function sceneSeed(sceneId: string): number {
  let hash = 2166136261
  for (let index = 0; index < sceneId.length; index += 1) {
    hash ^= sceneId.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return (hash >>> 0) / 4294967296
}

// Smoothstep-eased dissolve progress for a scene transition.
export function transitionProgress(elapsedMs: number, durationMs: number): number {
  if (durationMs <= 0) return 1
  const t = Math.min(1, Math.max(0, elapsedMs / durationMs))
  return t * t * (3 - 2 * t)
}

// Emotion -> tint colour (soft, additive). Unknown emotions fall back to a
// neutral warm white so generator vocabulary can grow freely.
export function emotionTint(emotion: string | null | undefined): [number, number, number] {
  switch ((emotion || '').toLowerCase()) {
    case 'happy':
    case 'excited':
      return [1.0, 0.85, 0.55]
    case 'curious':
    case 'thinking':
      return [0.55, 0.9, 0.95]
    case 'serious':
    case 'strict':
      return [0.75, 0.75, 1.0]
    case 'sad':
    case 'worried':
      return [0.55, 0.65, 0.9]
    case 'explaining':
    case 'gentle':
      return [0.8, 1.0, 0.8]
    default:
      return [0.95, 0.95, 0.95]
  }
}

// Typewriter reveal: how many characters of `text` are visible after
// `elapsedMs` at `charsPerSecond`. CJK-aware in the simplest way — every
// code point costs one tick, which reads naturally for zh-CN dialogue.
export function typewriterVisibleChars(
  text: string, elapsedMs: number, charsPerSecond = 32,
): number {
  if (elapsedMs <= 0 || charsPerSecond <= 0) return 0
  const codePoints = [...text].length
  return Math.min(codePoints, Math.floor((elapsedMs / 1000) * charsPerSecond))
}

// ---------------------------------------------------------------------------
// WGSL — one fullscreen pass drawing everything procedurally
// ---------------------------------------------------------------------------

const STAGE_WGSL = /* wgsl */ `
struct StageUniforms {
  // x: width, y: height, z: timeSeconds, w: transition [0,1]
  a: vec4f,
  // x: styleIndex, y: seedFrom, z: seedTo, w: motionScale
  b: vec4f,
  // xyz: emotion tint, w: emotion strength [0,1]
  tint: vec4f,
}

@group(0) @binding(0) var<uniform> u: StageUniforms;

fn hash2(p: vec2f) -> f32 {
  let h = dot(p, vec2f(127.1, 311.7));
  return fract(sin(h) * 43758.5453123);
}

fn noise2(p: vec2f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let s = f * f * (3.0 - 2.0 * f);
  let a = hash2(i);
  let b = hash2(i + vec2f(1.0, 0.0));
  let c = hash2(i + vec2f(0.0, 1.0));
  let d = hash2(i + vec2f(1.0, 1.0));
  return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

fn skyTopOf(style: f32) -> vec3f {
  if (style > 1.5) { return vec3f(0.02, 0.05, 0.12); }   // SCIENCE
  if (style > 0.5) { return vec3f(0.16, 0.09, 0.32); }   // FANTASY
  return vec3f(0.99, 0.82, 0.65);                        // CAMPUS
}

fn skyBottomOf(style: f32) -> vec3f {
  if (style > 1.5) { return vec3f(0.05, 0.14, 0.25); }
  if (style > 0.5) { return vec3f(0.42, 0.16, 0.38); }
  return vec3f(0.65, 0.78, 0.98);
}

fn accentOf(style: f32) -> vec3f {
  if (style > 1.5) { return vec3f(0.35, 0.85, 1.0); }
  if (style > 0.5) { return vec3f(0.85, 0.62, 1.0); }
  return vec3f(1.0, 0.72, 0.82);
}

// One drifting particle per grid cell; cheap and resolution-independent.
fn particles(uv: vec2f, time: f32, seed: f32, style: f32, motion: f32) -> f32 {
  var glow = 0.0;
  let cells = 9.0;
  let drift = select(vec2f(0.015, -0.045), vec2f(0.0, 0.02), style > 1.5) * motion;
  let p = uv * cells + drift * time * cells + seed * 37.0;
  let cell = floor(p);
  for (var dx = -1; dx <= 1; dx += 1) {
    for (var dy = -1; dy <= 1; dy += 1) {
      let c = cell + vec2f(f32(dx), f32(dy));
      let rnd = hash2(c);
      let wobble = vec2f(
        sin(time * (0.4 + rnd) * motion + rnd * 6.28),
        cos(time * (0.3 + rnd * 0.7) * motion + rnd * 6.28),
      ) * 0.25;
      let center = c + 0.5 + wobble * 0.5 + (vec2f(hash2(c + 11.0), hash2(c + 23.0)) - 0.5);
      let d = distance(p, center);
      let radius = 0.045 + rnd * 0.05;
      let tw = 0.6 + 0.4 * sin(time * (1.0 + rnd * 3.0) * motion + rnd * 40.0);
      glow += smoothstep(radius, 0.0, d) * tw * step(0.35, rnd);
    }
  }
  return glow;
}

fn scene(uv: vec2f, aspect: vec2f, time: f32, seed: f32, style: f32, motion: f32) -> vec3f {
  var color = mix(skyTopOf(style), skyBottomOf(style), uv.y);
  let accent = accentOf(style);

  // Soft rolling band (clouds / aurora / horizon glow) varied by the seed.
  let bandY = 0.35 + 0.3 * seed;
  let n = noise2(vec2f(uv.x * (2.0 + seed * 3.0) + time * 0.05 * motion + seed * 90.0, uv.y * 3.0));
  let band = smoothstep(0.35, 0.0, abs(uv.y - bandY - (n - 0.5) * 0.18));
  color += accent * band * 0.22;

  if (style > 1.5) {
    // SCIENCE: star field + glowing grid floor.
    let star = step(0.986, hash2(floor(uv * aspect * 90.0 + seed * 51.0)));
    color += vec3f(star) * (0.5 + 0.5 * sin(time * 2.0 * motion + uv.x * 40.0));
    let floorLine = smoothstep(0.012, 0.0, abs(fract((uv.y - 0.78) * 14.0) - 0.5) * step(0.78, uv.y));
    color += accent * floorLine * 0.35 * step(0.78, uv.y);
  } else if (style < 0.5) {
    // CAMPUS: sun disc + warm light shafts.
    let sun = vec2f(0.72 + 0.15 * (seed - 0.5), 0.24);
    let d = distance(uv * aspect, sun * aspect);
    color += vec3f(1.0, 0.85, 0.6) * smoothstep(0.22, 0.0, d) * 0.55;
    let shaft = max(0.0, sin((uv.x + uv.y * 0.35) * 9.0 + seed * 20.0)) * (1.0 - uv.y);
    color += vec3f(1.0, 0.9, 0.7) * shaft * 0.06;
  } else {
    // FANTASY: twin moons.
    let moon = vec2f(0.24 + 0.4 * seed, 0.2);
    let d = distance(uv * aspect, moon * aspect);
    color += accent * smoothstep(0.09, 0.0, d) * 0.8;
    color += accent * smoothstep(0.16, 0.05, d) * 0.2;
  }

  color += accent * particles(uv, time, seed, style, motion) * 0.6;
  return color;
}

struct VsOut {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
}

@vertex
fn vs(@builtin(vertex_index) index: u32) -> VsOut {
  // Fullscreen triangle.
  var out: VsOut;
  let x = f32(i32(index) - 1);
  let y = f32(i32(index & 1u) * 2 - 1);
  out.position = vec4f(x * 3.0, y * 3.0, 0.0, 1.0);
  out.uv = vec2f(out.position.x, -out.position.y) * 0.5 + 0.5;
  return out;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4f {
  let uv = in.uv;
  let aspect = vec2f(u.a.x / u.a.y, 1.0);
  let time = u.a.z;
  let motion = u.b.w;

  let from = scene(uv, aspect, time, u.b.y, u.b.x, motion);
  let to = scene(uv, aspect, time, u.b.z, u.b.x, motion);

  // Noise-driven dissolve between scene compositions.
  let dissolve = smoothstep(u.a.w - 0.15, u.a.w + 0.15, noise2(uv * 7.0 + u.b.z * 31.0));
  var color = mix(to, from, dissolve);

  // Emotion tint pulse.
  color = mix(color, color * (0.55 + 0.45 * u.tint.xyz) + u.tint.xyz * 0.12, u.tint.w);

  // Gentle vignette to frame the dialogue overlay.
  let v = distance(uv, vec2f(0.5, 0.46));
  color *= 1.0 - smoothstep(0.55, 0.95, v) * 0.45;

  return vec4f(color, 1.0);
}
`

// ---------------------------------------------------------------------------
// Stage implementation
// ---------------------------------------------------------------------------

const TRANSITION_MS = 900
const EMOTION_FADE_MS = 400

interface StageState {
  style: StageStyle
  seedFrom: number
  seedTo: number
  transitionElapsed: number
  time: number
  motionScale: number
  tint: [number, number, number]
  tintStrength: number
  tintTarget: number
}

function createState(style: StageStyle, reducedMotion: boolean): StageState {
  return {
    style,
    seedFrom: 0.5,
    seedTo: 0.5,
    transitionElapsed: TRANSITION_MS,
    time: 0,
    motionScale: reducedMotion ? 0.15 : 1,
    tint: [0.95, 0.95, 0.95],
    tintStrength: 0,
    tintTarget: 0,
  }
}

function advance(state: StageState, deltaMs: number): void {
  state.time += deltaMs
  state.transitionElapsed = Math.min(state.transitionElapsed + deltaMs, TRANSITION_MS)
  const step = deltaMs / EMOTION_FADE_MS
  if (state.tintStrength < state.tintTarget) {
    state.tintStrength = Math.min(state.tintTarget, state.tintStrength + step)
  } else if (state.tintStrength > state.tintTarget) {
    state.tintStrength = Math.max(state.tintTarget, state.tintStrength - step)
  }
}

async function createWebGpuBackend(
  canvas: HTMLCanvasElement, state: StageState,
): Promise<{ frame(): void; resize(w: number, h: number): void; dispose(): void } | null> {
  const gpu = (navigator as Navigator & { gpu?: GPU }).gpu
  if (!gpu) return null
  const adapter = await gpu.requestAdapter()
  if (!adapter) return null
  const device = await adapter.requestDevice()
  const context = canvas.getContext('webgpu') as GPUCanvasContext | null
  if (!context) return null
  const format = gpu.getPreferredCanvasFormat()
  context.configure({ device, format, alphaMode: 'opaque' })

  const module = device.createShaderModule({ code: STAGE_WGSL })
  const pipeline = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module, entryPoint: 'vs' },
    fragment: { module, entryPoint: 'fs', targets: [{ format }] },
    primitive: { topology: 'triangle-list' },
  })
  const uniformBuffer = device.createBuffer({
    size: 48,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  })
  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: { buffer: uniformBuffer } }],
  })
  const uniforms = new Float32Array(12)
  let disposed = false

  return {
    frame() {
      if (disposed) return
      uniforms[0] = canvas.width
      uniforms[1] = canvas.height
      uniforms[2] = state.time / 1000
      uniforms[3] = transitionProgress(state.transitionElapsed, TRANSITION_MS)
      uniforms[4] = STYLE_INDEX[state.style]
      uniforms[5] = state.seedFrom
      uniforms[6] = state.seedTo
      uniforms[7] = state.motionScale
      uniforms[8] = state.tint[0]
      uniforms[9] = state.tint[1]
      uniforms[10] = state.tint[2]
      uniforms[11] = state.tintStrength
      device.queue.writeBuffer(uniformBuffer, 0, uniforms)

      const encoder = device.createCommandEncoder()
      const pass = encoder.beginRenderPass({
        colorAttachments: [{
          view: context.getCurrentTexture().createView(),
          loadOp: 'clear',
          clearValue: { r: 0, g: 0, b: 0, a: 1 },
          storeOp: 'store',
        }],
      })
      pass.setPipeline(pipeline)
      pass.setBindGroup(0, bindGroup)
      pass.draw(3)
      pass.end()
      device.queue.submit([encoder.finish()])
    },
    resize(width, height) {
      canvas.width = Math.max(1, width)
      canvas.height = Math.max(1, height)
    },
    dispose() {
      disposed = true
      uniformBuffer.destroy()
      device.destroy()
    },
  }
}

function createCanvas2dBackend(
  canvas: HTMLCanvasElement, state: StageState,
): { frame(): void; resize(w: number, h: number): void; dispose(): void } {
  const context = canvas.getContext('2d')
  return {
    frame() {
      if (!context) return
      const { width, height } = canvas
      const palette = stylePalette(state.style)
      const toCss = (c: [number, number, number], mul = 1) =>
        `rgb(${Math.round(c[0] * 255 * mul)}, ${Math.round(c[1] * 255 * mul)}, ${Math.round(c[2] * 255 * mul)})`
      const gradient = context.createLinearGradient(0, 0, 0, height)
      gradient.addColorStop(0, toCss(palette.skyTop))
      gradient.addColorStop(1, toCss(palette.skyBottom))
      context.fillStyle = gradient
      context.fillRect(0, 0, width, height)

      // Drifting accents, seeded per scene.
      context.fillStyle = toCss(palette.accent)
      const time = state.time / 1000
      for (let index = 0; index < 24; index += 1) {
        const rnd = sceneSeed(`${state.seedTo}:${index}`)
        const x = ((rnd + time * 0.02 * state.motionScale) % 1) * width
        const y = ((rnd * 7.13 + index / 24 + time * 0.01) % 1) * height
        const radius = 1.5 + rnd * 3
        context.globalAlpha = 0.25 + 0.3 * Math.abs(Math.sin(time + index))
        context.beginPath()
        context.arc(x, y, radius, 0, Math.PI * 2)
        context.fill()
      }
      context.globalAlpha = 1

      // Dissolve approximation: dip to the sky colour while transitioning.
      const t = transitionProgress(state.transitionElapsed, TRANSITION_MS)
      if (t < 1) {
        context.globalAlpha = 1 - t
        context.fillStyle = toCss(palette.skyBottom, 0.8)
        context.fillRect(0, 0, width, height)
        context.globalAlpha = 1
      }
      if (state.tintStrength > 0.01) {
        context.globalAlpha = state.tintStrength * 0.15
        context.fillStyle = toCss(state.tint)
        context.fillRect(0, 0, width, height)
        context.globalAlpha = 1
      }
    },
    resize(width, height) {
      canvas.width = Math.max(1, width)
      canvas.height = Math.max(1, height)
    },
    dispose() {
      // nothing to release
    },
  }
}

export async function createStage(options: StageOptions): Promise<VisualStage> {
  const state = createState(options.style ?? 'CAMPUS', options.reducedMotion ?? false)
  const canvas = options.canvas
  const webgpu = await createWebGpuBackend(canvas, state).catch(() => null)
  const backend = webgpu ?? createCanvas2dBackend(canvas, state)

  return {
    backend: webgpu ? 'webgpu' : 'canvas2d',
    showScene(sceneId) {
      state.seedFrom = state.seedTo
      state.seedTo = sceneSeed(sceneId)
      state.transitionElapsed = 0
    },
    setStyle(style) {
      state.style = style
    },
    setEmotion(emotion) {
      if (emotion === null) {
        state.tintTarget = 0
        return
      }
      state.tint = emotionTint(emotion)
      state.tintTarget = 1
    },
    frame(deltaMs) {
      advance(state, Math.max(0, Math.min(deltaMs, 250)))
      backend.frame()
    },
    resize(width, height) {
      backend.resize(width, height)
    },
    dispose() {
      backend.dispose()
    },
  }
}
