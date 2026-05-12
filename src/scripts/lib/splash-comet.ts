// Canvas2D overlay that renders the splash comet as a streak of light along
// the infinity path. The head is a hot white core with an accent-colored
// radial halo; behind it ~50 sampled points trail off via exponential alpha
// falloff and shrinking radius. All samples draw with additive blending
// (globalCompositeOperation = "lighter") so overlapping points sum into a
// luminous streak instead of reading as discrete dots.
//
// Path samples come from the SVG `<path>`'s native getPointAtLength(), which
// the engine precomputes and caches internally so per-frame sampling is
// cheap. Cleanup cancels rAF and disconnects the ResizeObserver - call it
// before removing the splash from the DOM.
//
// Bails to canvas display:none (no comet at all) when:
//   - prefers-reduced-motion is set
//   - data-perf-mode="on" (TV / Leanback)
//   - Canvas2D context unavailable

const CYCLE_MS = 6000
const TRAIL_SAMPLES = 52
const TRAIL_LENGTH_FRAC = 0.2

const ACCENT_FALLBACK: [number, number, number] = [0.91, 0.5, 0.78]

function parseAccent(): [number, number, number] {
  try {
    const probe = document.createElement("span")
    probe.style.color = "var(--color-accent)"
    probe.style.display = "none"
    document.body.appendChild(probe)
    const resolved = getComputedStyle(probe).color
    probe.remove()
    if (!resolved) return ACCENT_FALLBACK

    const tmp = document.createElement("canvas")
    tmp.width = 1
    tmp.height = 1
    const tctx = tmp.getContext("2d")
    if (!tctx) return ACCENT_FALLBACK
    tctx.fillStyle = resolved
    tctx.fillRect(0, 0, 1, 1)
    const data = tctx.getImageData(0, 0, 1, 1).data
    return [data[0] / 255, data[1] / 255, data[2] / 255]
  } catch {
    return ACCENT_FALLBACK
  }
}

export function setupSplashComet(splash: HTMLElement): () => void {
  const canvas = splash.querySelector(".xt-app-splash__comet") as HTMLCanvasElement | null
  const pathEl = splash.querySelector("#xt-app-splash-path") as SVGPathElement | null
  const svgEl = splash.querySelector(".xt-app-splash__svg") as SVGSVGElement | null
  if (!canvas || !pathEl) return () => {}

  const reduced =
    window.matchMedia("(prefers-reduced-motion: reduce)").matches ||
    document.documentElement.getAttribute("data-perf-mode") === "on"
  if (reduced) {
    canvas.style.display = "none"
    return () => {}
  }

  const ctx = canvas.getContext("2d", { alpha: true })
  if (!ctx) {
    canvas.style.display = "none"
    return () => {}
  }

  let pathLen = 0
  try { pathLen = pathEl.getTotalLength() } catch {}
  if (pathLen <= 0) {
    canvas.style.display = "none"
    return () => {}
  }

  const accent = parseAccent()
  const ar = Math.round(accent[0] * 255)
  const ag = Math.round(accent[1] * 255)
  const ab = Math.round(accent[2] * 255)
  const accentStr = `${ar}, ${ag}, ${ab}`

  const dpr = Math.min(window.devicePixelRatio || 1, 2)
  // SVG user units (viewBox 0-24) -> canvas pixels, plus an offset for the
  // SVG's position inside the (larger) canvas. The mark-wrap pads the canvas
  // out past the SVG so the comet's halo can bloom freely.
  let userToPx = 1
  let offsetX = 0
  let offsetY = 0

  const resize = () => {
    const canvasRect = canvas.getBoundingClientRect()
    const cssW = canvasRect.width || 1
    const cssH = canvasRect.height || 1
    canvas.width = Math.max(1, Math.round(cssW * dpr))
    canvas.height = Math.max(1, Math.round(cssH * dpr))
    if (svgEl) {
      const svgRect = svgEl.getBoundingClientRect()
      offsetX = (svgRect.left - canvasRect.left) * dpr
      offsetY = (svgRect.top - canvasRect.top) * dpr
      userToPx = (svgRect.width / 24) * dpr
    } else {
      offsetX = 0
      offsetY = 0
      userToPx = (cssW / 24) * dpr
    }
  }
  resize()

  let ro: ResizeObserver | null = null
  if (typeof ResizeObserver !== "undefined") {
    ro = new ResizeObserver(resize)
    ro.observe(canvas)
  } else {
    window.addEventListener("resize", resize)
  }

  let rafId = 0
  let running = true
  const startTime = performance.now()

  const draw = () => {
    if (!running) return
    const elapsed = (performance.now() - startTime) % CYCLE_MS
    const headDist = (elapsed / CYCLE_MS) * pathLen

    ctx.clearRect(0, 0, canvas.width, canvas.height)
    ctx.globalCompositeOperation = "lighter"

    // Trail (drawn tail-first so the head sample is the last/topmost layer).
    for (let i = TRAIL_SAMPLES; i >= 1; i--) {
      const t = i / TRAIL_SAMPLES // 0 at head, 1 at tail
      let dist = headDist - t * TRAIL_LENGTH_FRAC * pathLen
      while (dist < 0) dist += pathLen
      while (dist >= pathLen) dist -= pathLen

      const pt = pathEl.getPointAtLength(dist)
      const x = offsetX + pt.x * userToPx
      const y = offsetY + pt.y * userToPx

      const alpha = Math.pow(1 - t, 2.2) * 0.55
      const radius = (2.4 - t * 2.0) * dpr
      if (radius < 0.3) continue

      ctx.fillStyle = `rgba(${accentStr}, ${alpha})`
      ctx.beginPath()
      ctx.arc(x, y, radius, 0, Math.PI * 2)
      ctx.fill()
    }

    // Head: accent halo + hot white core
    const headPt = pathEl.getPointAtLength(headDist)
    const hx = offsetX + headPt.x * userToPx
    const hy = offsetY + headPt.y * userToPx

    const haloR = 16 * dpr
    const halo = ctx.createRadialGradient(hx, hy, 0, hx, hy, haloR)
    halo.addColorStop(0, `rgba(${accentStr}, 0.85)`)
    halo.addColorStop(0.35, `rgba(${accentStr}, 0.30)`)
    halo.addColorStop(1, `rgba(${accentStr}, 0)`)
    ctx.fillStyle = halo
    ctx.beginPath()
    ctx.arc(hx, hy, haloR, 0, Math.PI * 2)
    ctx.fill()

    const coreR = 3.4 * dpr
    const core = ctx.createRadialGradient(hx, hy, 0, hx, hy, coreR)
    core.addColorStop(0, "rgba(255, 255, 255, 1)")
    core.addColorStop(0.45, "rgba(255, 255, 255, 0.7)")
    core.addColorStop(1, `rgba(${accentStr}, 0)`)
    ctx.fillStyle = core
    ctx.beginPath()
    ctx.arc(hx, hy, coreR, 0, Math.PI * 2)
    ctx.fill()

    rafId = requestAnimationFrame(draw)
  }
  draw()

  return () => {
    running = false
    if (rafId) cancelAnimationFrame(rafId)
    if (ro) ro.disconnect()
    else window.removeEventListener("resize", resize)
  }
}
