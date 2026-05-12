// Procedural WebGL backdrop for the splash. A fullscreen fragment shader
// renders drifting fbm noise, a soft fuchsia radial bloom, and very subtle
// film grain - cinema-lobby atmosphere, GPU-rendered. The shader reads the
// current theme's --color-accent and --color-bg from CSS so it tracks light
// and dark modes automatically.
//
// Falls back to a no-op (leaving the CSS radial-gradient on #xt-app-splash
// visible) when prefers-reduced-motion is set, perf-mode is on, or the
// runtime doesn't have WebGL2. Cleanup cancels rAF and releases GL state -
// call it before removing the splash element from the DOM.

const VERTEX_SHADER = `#version 300 es
in vec2 a_pos;
void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }`

const FRAGMENT_SHADER = `#version 300 es
precision highp float;
out vec4 fragColor;
uniform vec2 u_resolution;
uniform float u_time;
uniform vec3 u_accent;
uniform vec3 u_bg;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm(vec2 p) {
  float v = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 4; i++) {
    v += amp * vnoise(p);
    p *= 2.02;
    amp *= 0.5;
  }
  return v;
}

void main() {
  vec2 uv = (gl_FragCoord.xy - 0.5 * u_resolution) / min(u_resolution.x, u_resolution.y);

  // Slowly drifting volumetric noise. Domain-warp the second octave so the
  // pattern feels organic rather than tiled.
  float t = u_time * 0.025;
  vec2 q = vec2(fbm(uv * 1.4 + t), fbm(uv * 1.4 + t + 5.1));
  float n = fbm(uv * 1.8 + q * 0.55);

  // Radial bloom from center, modulated by the noise field so it breathes
  // organically instead of pulsing on a fixed timer.
  float dist = length(uv);
  float bloom = exp(-dist * 2.2) * (0.50 + 0.50 * smoothstep(0.0, 1.0, n));

  vec3 color = mix(u_bg, u_accent, bloom * 0.42);

  // Very faint film grain to break up flat regions; magnitude kept tiny so
  // it reads as texture, not noise.
  float grain = (hash(gl_FragCoord.xy + u_time * 73.0) - 0.5) * 0.018;
  color += grain;

  fragColor = vec4(color, 1.0);
}`

/**
 * Mounts the procedural backdrop on `<canvas id="xt-app-splash-bg">` inside
 * the splash element. Returns a cleanup function that must be called before
 * the splash is removed from the DOM.
 */
export function setupSplashBackdrop(splash: HTMLElement): () => void {
  const canvas = splash.querySelector("#xt-app-splash-bg") as HTMLCanvasElement | null
  if (!canvas) return () => {}

  // Skip the shader entirely when the user has opted out of motion or the
  // app is running in perf mode (auto-enabled on TV / Leanback). The CSS
  // radial-gradient on #xt-app-splash is the visible backdrop in that case.
  const reduced =
    window.matchMedia("(prefers-reduced-motion: reduce)").matches ||
    document.documentElement.getAttribute("data-perf-mode") === "on"
  if (reduced) {
    canvas.style.display = "none"
    return () => {}
  }

  const gl = canvas.getContext("webgl2", {
    antialias: false,
    alpha: false,
    powerPreference: "low-power",
  }) as WebGL2RenderingContext | null
  if (!gl) {
    canvas.style.display = "none"
    return () => {}
  }

  // Cap DPR to keep low-end TV boxes from rendering 4K fragments. The shader
  // is smooth enough that 1.5x looks identical to 2x at normal viewing.
  const dpr = Math.min(window.devicePixelRatio || 1, 1.5)
  let pixelW = 0
  let pixelH = 0
  const resize = () => {
    const cssW = canvas.clientWidth || splash.clientWidth || window.innerWidth
    const cssH = canvas.clientHeight || splash.clientHeight || window.innerHeight
    pixelW = Math.max(1, Math.round(cssW * dpr))
    pixelH = Math.max(1, Math.round(cssH * dpr))
    canvas.width = pixelW
    canvas.height = pixelH
    gl.viewport(0, 0, pixelW, pixelH)
  }
  resize()
  window.addEventListener("resize", resize)

  const compile = (type: number, source: string): WebGLShader | null => {
    const sh = gl.createShader(type)
    if (!sh) return null
    gl.shaderSource(sh, source)
    gl.compileShader(sh)
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      gl.deleteShader(sh)
      return null
    }
    return sh
  }

  const bail = (rafId: number, prog: WebGLProgram | null, vs: WebGLShader | null, fs: WebGLShader | null, buf: WebGLBuffer | null) => {
    if (rafId) cancelAnimationFrame(rafId)
    window.removeEventListener("resize", resize)
    try {
      if (prog) gl.deleteProgram(prog)
      if (vs) gl.deleteShader(vs)
      if (fs) gl.deleteShader(fs)
      if (buf) gl.deleteBuffer(buf)
    } catch {}
    canvas.style.display = "none"
  }

  const vs = compile(gl.VERTEX_SHADER, VERTEX_SHADER)
  const fs = compile(gl.FRAGMENT_SHADER, FRAGMENT_SHADER)
  if (!vs || !fs) {
    bail(0, null, vs, fs, null)
    return () => {}
  }

  const prog = gl.createProgram()
  if (!prog) {
    bail(0, null, vs, fs, null)
    return () => {}
  }
  gl.attachShader(prog, vs)
  gl.attachShader(prog, fs)
  gl.linkProgram(prog)
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    bail(0, prog, vs, fs, null)
    return () => {}
  }

  // Full-screen triangle (cheaper than a quad - 3 verts cover the viewport
  // when sampled with NDC outside [-1, 1]).
  const positions = new Float32Array([-1, -1, 3, -1, -1, 3])
  const buf = gl.createBuffer()
  gl.bindBuffer(gl.ARRAY_BUFFER, buf)
  gl.bufferData(gl.ARRAY_BUFFER, positions, gl.STATIC_DRAW)

  const posLoc = gl.getAttribLocation(prog, "a_pos")
  gl.enableVertexAttribArray(posLoc)
  gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 0, 0)

  const uRes = gl.getUniformLocation(prog, "u_resolution")
  const uTime = gl.getUniformLocation(prog, "u_time")
  const uAccent = gl.getUniformLocation(prog, "u_accent")
  const uBg = gl.getUniformLocation(prog, "u_bg")

  // Resolve theme tokens to sRGB. Modern Chromium preserves oklch()/color()
  // notation in getComputedStyle output, so regex-parsing the result yields
  // garbage. Canvas 2D, on the other hand, gamut-maps any CSS color format
  // (oklch, lab, color(), rgb, hex, even light-dark()) to sRGB bytes via the
  // fillStyle setter - so we draw 1 pixel and read it back.
  const colorProbe = document.createElement("canvas")
  colorProbe.width = 1
  colorProbe.height = 1
  const colorCtx = colorProbe.getContext("2d")

  const parseColor = (
    cssExpression: string,
    fallback: [number, number, number]
  ): [number, number, number] => {
    if (!cssExpression || !colorCtx) return fallback
    try {
      // Resolve through a probe element first so any var()/light-dark()/etc.
      // chain is collapsed to a concrete color value the canvas can accept.
      const probe = document.createElement("span")
      probe.style.color = cssExpression
      probe.style.display = "none"
      document.body.appendChild(probe)
      const resolved = getComputedStyle(probe).color
      probe.remove()
      if (!resolved) return fallback

      colorCtx.clearRect(0, 0, 1, 1)
      colorCtx.fillStyle = "#000"
      colorCtx.fillStyle = resolved
      colorCtx.fillRect(0, 0, 1, 1)
      const pixel = colorCtx.getImageData(0, 0, 1, 1).data
      return [pixel[0] / 255, pixel[1] / 255, pixel[2] / 255]
    } catch {
      return fallback
    }
  }

  // Read directly via var() inside a probe so light-dark() resolves against
  // the document's color scheme; reading the raw custom-property value would
  // give us the unresolved light-dark(...) expression instead.
  const accentRgb = parseColor("var(--color-accent)", [0.91, 0.5, 0.78])
  const bgRgb = parseColor("var(--color-bg)", [0.055, 0.086, 0.156])

  let rafId = 0
  const startTime = performance.now()
  let running = true

  const render = () => {
    if (!running) return
    const t = (performance.now() - startTime) / 1000
    gl.useProgram(prog)
    gl.uniform2f(uRes, pixelW, pixelH)
    gl.uniform1f(uTime, t)
    gl.uniform3f(uAccent, accentRgb[0], accentRgb[1], accentRgb[2])
    gl.uniform3f(uBg, bgRgb[0], bgRgb[1], bgRgb[2])
    gl.drawArrays(gl.TRIANGLES, 0, 3)
    rafId = requestAnimationFrame(render)
  }
  render()

  return () => {
    running = false
    if (rafId) cancelAnimationFrame(rafId)
    window.removeEventListener("resize", resize)
    try {
      gl.deleteProgram(prog)
      gl.deleteShader(vs)
      gl.deleteShader(fs)
      gl.deleteBuffer(buf)
      // Encourage the browser to free the context on cleanup. Not strictly
      // required - the canvas detachment usually does it - but harmless.
      gl.getExtension("WEBGL_lose_context")?.loseContext()
    } catch {}
  }
}
