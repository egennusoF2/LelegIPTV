// Unified mount surface for the four playback backends.
//
// Returns a tagged union so call sites can branch cleanly between
// embedded (Video.js / HTML5) and external (MPV / VLC) playback. The
// embedded handle exposes a Video.js-shaped subset; the external launch
// is a fire-and-forget spawn with no progress / pause feedback.
//
// Reused utilities:
//   - getPlayerBackend    src/scripts/lib/app-settings.js
//   - getPlayerPath       src/scripts/lib/app-settings.js
//   - getPlayerExtraArgs  src/scripts/lib/app-settings.js
//   - log                 src/scripts/lib/log.js
//
// Desktop only - external backends invoke a Tauri command that's gated
// off on Android/iOS at the Rust side.

import { log } from "@/scripts/lib/log.js"
import {
  getPlayerBackend,
  getPlayerPath,
  getPlayerExtraArgs,
  getPlayerReuseInstance,
  getUserAgent,
  EXTERNAL_PLAYER_BACKENDS,
} from "@/scripts/lib/app-settings.js"

export type PlayerBackend = "videojs" | "artplayer" | "mpv" | "vlc"
export type ExternalPlayerKind = "mpv" | "vlc"

export const RESUME_MIN_SECONDS_DEFAULT = 5

export interface VjsLikeHandle {
  src(opts: { src: string; type: string }): void
  play(): Promise<unknown> | void
  pause(): void
  paused?(): boolean
  muted?(value?: boolean): boolean | void
  reset?(): void
  dispose?(): void
  duration?(): number
  currentTime?(value?: number): number
  on(event: string, fn: (...args: unknown[]) => void): void
  off?(event: string, fn: (...args: unknown[]) => void): void
  one?(event: string, fn: (...args: unknown[]) => void): void
  el?(): HTMLElement
  error?(): unknown
  requestFullscreen?(): Promise<void> | void
  userActive?(active: boolean): void
}

export interface ExternalLaunchOptions {
  userAgent?: string | null
  referer?: string | null
  resumeSeconds?: number
  /** Localised "Couldn't launch <player>" toast title; caller-provided so we don't depend on i18n here. */
  // (not a function dep on purpose; toast wiring is at the call site)
}

export interface ExternalLauncher {
  /** Spawn the external player or reuse an existing window. Resolves once the IPC / spawn returns. */
  launch(
    src: string,
    options?: ExternalLaunchOptions,
  ): Promise<{ pid: number; reused: boolean }>
  kind: ExternalPlayerKind
  path: string
}

export type Mounted =
  | { kind: "embedded"; backend: "videojs" | "artplayer" | "native"; handle: VjsLikeHandle }
  | { kind: "external"; backend: ExternalPlayerKind; launcher: ExternalLauncher }

export interface MountOptions {
  liveui?: boolean
  fluid?: boolean
  aspectRatio?: string
  preload?: string
  autoplay?: boolean
  /** Hide Video.js's built-in PiP toggle when an Android native bridge handles it. */
  pictureInPictureToggle?: boolean
  controlBar?: Record<string, unknown>
  html5?: Record<string, unknown>
}

const isTauri =
  typeof window !== "undefined" &&
  (!!(window as any).__TAURI_INTERNALS__ || !!(window as any).__TAURI__)

const isAndroid = (() => {
  if (typeof navigator === "undefined") return false
  return /Android/i.test(navigator.userAgent || "")
})()

export const externalPlayersAvailable = isTauri && !isAndroid

export const androidExternalAvailable =
  isTauri &&
  isAndroid &&
  typeof window !== "undefined" &&
  !!(window as any).AndroidIntent

let invokePromise: Promise<((cmd: string, args: unknown) => Promise<unknown>) | null> | null = null
async function getInvoke() {
  if (!externalPlayersAvailable) return null
  if (!invokePromise) {
    invokePromise = import("@tauri-apps/api/core")
      .then((mod) => mod.invoke as (cmd: string, args: unknown) => Promise<unknown>)
      .catch((error) => {
        log.warn("[xt:player] @tauri-apps/api/core import failed:", error)
        return null
      })
  }
  return invokePromise
}

// ---------------------------------------------------------------------------
// Argv builders (pure, unit-testable)
// ---------------------------------------------------------------------------
export interface ArgvInput {
  src: string
  userAgent?: string | null
  referer?: string | null
  resumeSeconds?: number
  extraArgs?: string[]
  /** Resume threshold; below this we don't pass a seek arg (avoids restart-from-credits glitch). */
  resumeMinSeconds?: number
}

export function buildMpvArgs(input: ArgvInput): string[] {
  const minResume = input.resumeMinSeconds ?? RESUME_MIN_SECONDS_DEFAULT
  const out: string[] = ["--force-window=immediate", "--no-terminal"]
  if (input.userAgent) out.push(`--user-agent=${input.userAgent}`)
  if (input.referer) out.push(`--referrer=${input.referer}`)
  if (/^rtsp:\/\//i.test(input.src)) {
    out.push("--demuxer-lavf-o=rtsp_transport=udp+tcp")
  }
  const resume = Number(input.resumeSeconds || 0)
  if (Number.isFinite(resume) && resume > minResume) {
    out.push(`--start=${Math.floor(resume)}`)
  }
  for (const arg of input.extraArgs || []) {
    if (arg && arg.trim()) out.push(arg)
  }
  out.push(input.src)
  return out
}

export function buildVlcArgs(input: ArgvInput): string[] {
  const minResume = input.resumeMinSeconds ?? RESUME_MIN_SECONDS_DEFAULT
  const out: string[] = [
    "--no-qt-minimal-view",
    "--no-fullscreen",
    "--no-qt-error-dialogs",
    "--play-and-exit",
  ]
  if (input.userAgent) out.push(`--http-user-agent=${input.userAgent}`)
  if (input.referer) out.push(`--http-referrer=${input.referer}`)
  const resume = Number(input.resumeSeconds || 0)
  if (Number.isFinite(resume) && resume > minResume) {
    out.push(`--start-time=${Math.floor(resume)}`)
  }
  for (const arg of input.extraArgs || []) {
    if (arg && arg.trim()) out.push(arg)
  }
  out.push(input.src)
  return out
}

export function buildArgsFor(kind: ExternalPlayerKind, input: ArgvInput): string[] {
  return kind === "mpv" ? buildMpvArgs(input) : buildVlcArgs(input)
}

// ---------------------------------------------------------------------------
// External launcher
// ---------------------------------------------------------------------------
export class PlayerNotConfiguredError extends Error {
  constructor(public readonly kind: ExternalPlayerKind) {
    super(`No path configured for ${kind}`)
    this.name = "PlayerNotConfiguredError"
  }
}

export class PlayerLaunchError extends Error {
  constructor(
    message: string,
    public readonly code: "NOT_FOUND" | "PERMISSION" | "TIMEOUT" | "OTHER",
    public readonly kind: ExternalPlayerKind,
    public readonly path: string,
  ) {
    super(message)
    this.name = "PlayerLaunchError"
  }
}

export function classifyError(raw: unknown, kind: ExternalPlayerKind, path: string): PlayerLaunchError {
  const msg = typeof raw === "string" ? raw : (raw as Error)?.message || String(raw)
  const code = msg.startsWith("NOT_FOUND")
    ? "NOT_FOUND"
    : msg.startsWith("PERMISSION")
      ? "PERMISSION"
      : msg.startsWith("TIMEOUT")
        ? "TIMEOUT"
        : "OTHER"
  return new PlayerLaunchError(msg, code, kind, path)
}

export function getExternalLauncher(kind: ExternalPlayerKind): ExternalLauncher {
  const path = getPlayerPath(kind)
  return {
    kind,
    path,
    async launch(src, options = {}) {
      if (!path) throw new PlayerNotConfiguredError(kind)
      const invoke = await getInvoke()
      if (!invoke) {
        throw new PlayerLaunchError(
          "OTHER:Tauri invoke unavailable",
          "OTHER",
          kind,
          path,
        )
      }
      const args = buildArgsFor(kind, {
        src,
        userAgent: options.userAgent ?? getUserAgent() ?? null,
        referer: options.referer ?? null,
        resumeSeconds: options.resumeSeconds,
        extraArgs: getPlayerExtraArgs(kind),
      })
      const reuse = getPlayerReuseInstance(kind)
        ? { kind, enabled: true, url: src }
        : { kind, enabled: false, url: src }
      try {
        const result = (await invoke("launch_external_player", {
          path,
          args,
          mode: "launch",
          reuse,
        })) as { pid?: number; reused?: boolean }
        return { pid: Number(result?.pid) || 0, reused: !!result?.reused }
      } catch (raw) {
        throw classifyError(raw, kind, path)
      }
    },
  }
}

// ---------------------------------------------------------------------------
// Android external handoff (parallel API to getExternalLauncher)
// ---------------------------------------------------------------------------
// The Android path doesn't spawn processes - it fires an Intent.ACTION_VIEW
// through the AndroidIntent bridge in MainActivity.kt. Two kinds:
//   "system"  - createChooser() so the user picks (Android remembers their
//               choice once they hit "Always").
//   "vlc"     - direct package-pinned launch to org.videolan.vlc. The UI
//               should only offer this when isVlcInstalled() returns true.

export type AndroidHandoffKind = "system" | "vlc"

interface AndroidIntentBridge {
  isVlcInstalled?: () => boolean
  isMxPlayerInstalled?: () => boolean
  viewStream?: (
    url: string,
    mime: string,
    userAgent: string,
    referer: string,
    title: string,
  ) => boolean
  openInVlc?: (
    url: string,
    mime: string,
    userAgent: string,
    referer: string,
    title: string,
  ) => boolean
  listVideoPlayerApps?: (url: string, mime: string) => string
  openInPackage?: (
    pkg: string,
    activity: string,
    url: string,
    mime: string,
    userAgent: string,
    referer: string,
    title: string,
  ) => boolean
}

export interface AndroidVideoApp {
  pkg: string
  label: string
  activity: string
  icon: string
}

function androidIntent(): AndroidIntentBridge | null {
  if (typeof window === "undefined") return null
  const bridge = (window as any).AndroidIntent as AndroidIntentBridge | undefined
  return bridge || null
}

export function isVlcInstalledOnAndroid(): boolean {
  try {
    return !!androidIntent()?.isVlcInstalled?.()
  } catch (err) {
    log.warn("[xt:player] AndroidIntent.isVlcInstalled threw:", err)
    return false
  }
}

export function isMxPlayerInstalledOnAndroid(): boolean {
  try {
    return !!androidIntent()?.isMxPlayerInstalled?.()
  } catch (err) {
    log.warn("[xt:player] AndroidIntent.isMxPlayerInstalled threw:", err)
    return false
  }
}

// Pick a sensible MIME hint for the Android Intent.
export function androidMimeForUrl(url: string | null | undefined): string {
  if (!url) return "video/*"
  const path = (url.split("?")[0] ?? "").toLowerCase()
  if (path.endsWith(".m3u8")) return "application/vnd.apple.mpegurl"
  if (path.endsWith(".ts")) return "video/mp2t"
  if (path.endsWith(".mp4") || path.endsWith(".m4v")) return "video/mp4"
  if (path.endsWith(".mkv")) return "video/x-matroska"
  if (path.endsWith(".webm")) return "video/webm"
  if (path.endsWith(".mov")) return "video/quicktime"
  if (path.endsWith(".avi")) return "video/x-msvideo"
  if (path.endsWith(".mpd")) return "application/dash+xml"
  if (/\/live\/[^/]+\/[^/]+\/\d+$/i.test(path)) {
    return "application/vnd.apple.mpegurl"
  }
  return "video/*"
}

export class AndroidHandoffError extends Error {
  constructor(
    message: string,
    public readonly code: "NO_BRIDGE" | "NO_HANDLER" | "VLC_MISSING" | "OTHER",
    public readonly kind: AndroidHandoffKind,
  ) {
    super(message)
    this.name = "AndroidHandoffError"
  }
}

export interface AndroidHandoffOptions {
  userAgent?: string | null
  referer?: string | null
  title?: string | null
  mime?: string | null
}

export interface AndroidHandoffLauncher {
  kind: AndroidHandoffKind
  available(): boolean
  launch(src: string, options?: AndroidHandoffOptions): Promise<void>
}

export function getAndroidHandoffLauncher(kind: AndroidHandoffKind): AndroidHandoffLauncher {
  return {
    kind,
    available() {
      if (!androidExternalAvailable) return false
      if (kind === "vlc") return isVlcInstalledOnAndroid()
      return true
    },
    async launch(src, options = {}) {
      const bridge = androidIntent()
      if (!bridge) {
        throw new AndroidHandoffError(
          "AndroidIntent bridge not available",
          "NO_BRIDGE",
          kind,
        )
      }
      const mime = options.mime || androidMimeForUrl(src)
      const userAgent = options.userAgent || getUserAgent() || ""
      const referer = options.referer || ""
      const title = options.title || ""
      try {
        let ok = false
        if (kind === "vlc") {
          if (!bridge.isVlcInstalled?.()) {
            throw new AndroidHandoffError(
              "VLC for Android is not installed",
              "VLC_MISSING",
              kind,
            )
          }
          ok = !!bridge.openInVlc?.(src, mime, userAgent, referer, title)
        } else {
          ok = !!bridge.viewStream?.(src, mime, userAgent, referer, title)
        }
        if (!ok) {
          throw new AndroidHandoffError(
            kind === "vlc"
              ? "VLC refused to open the stream"
              : "No app on this device can handle this stream",
            kind === "vlc" ? "OTHER" : "NO_HANDLER",
            kind,
          )
        }
      } catch (err) {
        if (err instanceof AndroidHandoffError) throw err
        log.warn("[xt:player] AndroidIntent threw:", err)
        throw new AndroidHandoffError(String(err), "OTHER", kind)
      }
    },
  }
}

// Pre-resolve the chooser candidates so the UI can present its own picker.
// Used to dodge a long-standing VLC-on-Android quirk where chooser-routed
// intents resolve to the wrong activity inside VLC (its playback service
// starts but the player activity never foregrounds). Pairs with
// openStreamInAndroidPackage(), which launches via setPackage() - the same
// reliable path the dedicated VLC button uses.
export function listAndroidVideoPlayerApps(
  url: string,
  mime?: string | null,
): AndroidVideoApp[] {
  const bridge = androidIntent()
  if (!bridge?.listVideoPlayerApps) return []
  const resolvedMime = mime || androidMimeForUrl(url)
  try {
    const json = bridge.listVideoPlayerApps(url, resolvedMime)
    if (!json) return []
    const parsed = JSON.parse(json)
    if (!Array.isArray(parsed)) return []
    return parsed
      .map((entry) => ({
        pkg: typeof entry?.pkg === "string" ? entry.pkg : "",
        label: typeof entry?.label === "string" ? entry.label : "",
        activity: typeof entry?.activity === "string" ? entry.activity : "",
        icon: typeof entry?.icon === "string" ? entry.icon : "",
      }))
      .filter((entry) => entry.pkg.length > 0)
  } catch (err) {
    log.warn("[xt:player] listVideoPlayerApps parse failed:", err)
    return []
  }
}

export interface AndroidPackageLaunchOptions extends AndroidHandoffOptions {
  /** Optional explicit activity component (from listAndroidVideoPlayerApps). */
  activity?: string | null
}

export async function openStreamInAndroidPackage(
  pkg: string,
  src: string,
  options: AndroidPackageLaunchOptions = {},
): Promise<void> {
  const bridge = androidIntent()
  if (!bridge?.openInPackage) {
    throw new AndroidHandoffError(
      "AndroidIntent bridge not available",
      "NO_BRIDGE",
      "system",
    )
  }
  const mime = options.mime || androidMimeForUrl(src)
  const userAgent = options.userAgent || getUserAgent() || ""
  const referer = options.referer || ""
  const title = options.title || ""
  const activity = options.activity || ""
  let ok = false
  try {
    ok = !!bridge.openInPackage(
      pkg,
      activity,
      src,
      mime,
      userAgent,
      referer,
      title,
    )
  } catch (err) {
    log.warn("[xt:player] AndroidIntent.openInPackage threw:", err)
    throw new AndroidHandoffError(String(err), "OTHER", "system")
  }
  if (!ok) {
    throw new AndroidHandoffError(
      `Couldn't launch ${pkg}`,
      "OTHER",
      "system",
    )
  }
}

export async function detectPlayer(
  kind: ExternalPlayerKind,
  candidatePath: string,
): Promise<{ ok: true; version: string } | { ok: false; error: PlayerLaunchError }> {
  if (!candidatePath) {
    return {
      ok: false,
      error: new PlayerLaunchError("NOT_FOUND:empty path", "NOT_FOUND", kind, ""),
    }
  }
  const invoke = await getInvoke()
  if (!invoke) {
    return {
      ok: false,
      error: new PlayerLaunchError(
        "OTHER:Tauri invoke unavailable",
        "OTHER",
        kind,
        candidatePath,
      ),
    }
  }
  const detectMode = kind === "vlc" ? "exists" : "detect"
  try {
    const result = (await invoke("launch_external_player", {
      path: candidatePath,
      args: [],
      mode: detectMode,
    })) as { version?: string }
    return { ok: true, version: String(result?.version || "").trim() }
  } catch (raw) {
    return { ok: false, error: classifyError(raw, kind, candidatePath) }
  }
}

// ---------------------------------------------------------------------------
// Container detection
// ---------------------------------------------------------------------------
// Two paths: a synchronous hint from URL extension or supplied MIME, and an
// async Content-Type probe used when the URL has no useful extension (e.g.
// Dispatcharr's `/proxy/ts/stream/<uuid>` or Xtream's bare `/live/<u>/<p>/<id>`
// which the server can serve as either HLS or raw TS).

type StreamKind = "hls" | "dash" | "ts" | "native"

function streamKindHint(src: string, type?: string): StreamKind | "unknown" {
  // URL extension wins: Live TV callers pass a stock
  // "application/x-mpegURL" MIME regardless of the real container, so
  // a contradicting extension overrides the MIME.
  if (/\.m3u8(\?|$)/i.test(src)) return "hls"
  if (/\.mpd(\?|$)/i.test(src)) return "dash"
  if (/\.ts(\?|$)/i.test(src)) return "ts"
  if (/\.(mp4|m4v|mkv|webm|mov|avi|m4a|mp3|aac|flac|ogg)(\?|$)/i.test(src)) return "native"

  const mime = (type || "").toLowerCase()
  if (mime.includes("dash+xml")) return "dash"
  if (mime.includes("mpegurl") || mime.includes("m3u8")) return "hls"
  if (mime === "video/mp2t" || mime === "video/mpeg") return "ts"
  if (mime.startsWith("video/") || mime.startsWith("audio/")) return "native"
  return "unknown"
}

const containerProbeCache = new Map<string, StreamKind>()

async function probeContainer(src: string): Promise<StreamKind> {
  let origin: string
  try {
    origin = new URL(src).origin
  } catch {
    return "hls"
  }
  const cached = containerProbeCache.get(origin)
  if (cached) return cached
  try {
    const { providerFetch } = await import("@/scripts/lib/provider-fetch.js")
    const controller =
      typeof AbortController !== "undefined" ? new AbortController() : null
    const timer = controller ? setTimeout(() => controller.abort(), 4000) : null
    let kind: StreamKind = "hls"
    try {
      const response = await providerFetch(src, {
        method: "GET",
        headers: { Range: "bytes=0-0" },
        signal: controller?.signal,
      })
      const contentType = (response.headers.get("content-type") || "").toLowerCase()
      if (contentType.includes("dash+xml") || contentType.includes("mpd")) {
        kind = "dash"
      } else if (contentType.includes("mpegurl") || contentType.includes("m3u8")) {
        kind = "hls"
      } else if (
        contentType.includes("mp2t") ||
        contentType.includes("mpeg-ts") ||
        contentType.includes("mpegts")
      ) {
        kind = "ts"
      } else if (
        contentType.startsWith("video/") ||
        contentType.startsWith("audio/")
      ) {
        kind = "native"
      }
      try {
        response.body?.cancel?.()
      } catch {}
    } finally {
      if (timer) clearTimeout(timer)
    }
    containerProbeCache.set(origin, kind)
    return kind
  } catch {
    return "hls"
  }
}

interface MpegtsHandle {
  destroy: () => void
}

interface DashHandle {
  destroy: () => void
}

async function attachDash(
  videoEl: HTMLVideoElement,
  url: string,
): Promise<DashHandle | null> {
  const dashMod = await import("dashjs")
  const dashjs = (dashMod as any).default || dashMod
  const factory = dashjs?.MediaPlayer
  if (!factory) {
    log.warn("[xt:player] dashjs MediaPlayer unavailable")
    return null
  }
  const player = factory().create()
  player.initialize(videoEl, url, true)
  return {
    destroy() {
      try { player.reset() } catch {}
    },
  }
}

async function attachMpegts(
  videoEl: HTMLVideoElement,
  url: string,
): Promise<MpegtsHandle | null> {
  const mpegtsMod = await import("mpegts.js")
  const mpegts = (mpegtsMod as any).default || mpegtsMod
  if (!mpegts?.isSupported?.()) {
    log.warn("[xt:player] mpegts.js unsupported in this WebView")
    return null
  }
  const player = mpegts.createPlayer({
    type: "mpegts",
    isLive: true,
    url,
  })
  player.attachMediaElement(videoEl)
  player.load()
  try {
    const playPromise = player.play?.()
    if (playPromise && typeof (playPromise as Promise<void>).catch === "function") {
      (playPromise as Promise<void>).catch(() => {})
    }
  } catch {}
  return {
    destroy() {
      try { player.unload() } catch {}
      try { player.detachMediaElement() } catch {}
      try { player.destroy() } catch {}
    },
  }
}

// ---------------------------------------------------------------------------
// Embedded mounts
// ---------------------------------------------------------------------------
async function mountVideoJs(
  videoEl: HTMLVideoElement,
  options: MountOptions,
): Promise<VjsLikeHandle> {
  const [{ default: videojs }] = await Promise.all([
    import("video.js"),
    import("video.js/dist/video-js.css"),
  ])
  const player = videojs(videoEl, {
    liveui: options.liveui ?? false,
    fluid: options.fluid ?? true,
    preload: options.preload ?? "auto",
    autoplay: options.autoplay ?? false,
    aspectRatio: options.aspectRatio ?? "16:9",
    controlBar: options.controlBar ?? {
      volumePanel: { inline: false },
      pictureInPictureToggle: options.pictureInPictureToggle ?? true,
      playbackRateMenuButton: true,
      subsCapsButton: true,
      audioTrackButton: true,
      fullscreenToggle: true,
    },
    html5: options.html5 ?? {
      vhs: {
        overrideNative: true,
        limitRenditionByPlayerDimensions: true,
        smoothQualityChange: true,
      },
    },
  }) as any

  let activeMpegts: MpegtsHandle | null = null
  let activeDash: DashHandle | null = null
  let pendingSrc: string | null = null

  function getUnderlyingVideo(): HTMLVideoElement | null {
    try {
      const tech = player.tech?.({ IWillNotUseThisInPlugins: true })
      const fromCall = tech?.el?.()
      if (fromCall instanceof HTMLVideoElement) return fromCall
      const fromField = tech?.el_
      if (fromField instanceof HTMLVideoElement) return fromField
    } catch {}
    return null
  }

  function destroyMpegts() {
    if (activeMpegts) {
      try { activeMpegts.destroy() } catch {}
      activeMpegts = null
    }
  }

  function destroyDash() {
    if (activeDash) {
      try { activeDash.destroy() } catch {}
      activeDash = null
    }
  }

  function loadHls(src: string) {
    destroyMpegts()
    destroyDash()
    player.src({ src, type: "application/x-mpegURL" })
  }

  function loadNative(src: string, type?: string) {
    destroyMpegts()
    destroyDash()
    player.src({ src, type: type || "video/mp4" })
  }

  async function loadDash(src: string) {
    destroyMpegts()
    destroyDash()
    try { player.pause?.() } catch {}
    try { player.reset() } catch {}
    const videoElement = getUnderlyingVideo()
    if (!videoElement) {
      player.src({ src, type: "application/dash+xml" })
      return
    }
    const handle = await attachDash(videoElement, src)
    if (!handle) {
      player.src({ src, type: "application/dash+xml" })
      return
    }
    if (pendingSrc !== src) {
      try { handle.destroy() } catch {}
      return
    }
    activeDash = handle
    try { player.hasStarted?.(true) } catch {}
  }

  async function loadTs(src: string) {
    destroyMpegts()
    destroyDash()
    try { player.pause?.() } catch {}
    try { player.reset() } catch {}
    const videoElement = getUnderlyingVideo()
    if (!videoElement) {
      loadHls(src)
      return
    }
    const handle = await attachMpegts(videoElement, src)
    if (!handle) {
      loadHls(src)
      return
    }
    if (pendingSrc !== src) {
      try { handle.destroy() } catch {}
      return
    }
    activeMpegts = handle
    try { player.hasStarted?.(true) } catch {}
  }

  const wrapped: VjsLikeHandle = {
    src({ src, type }) {
      pendingSrc = src
      const hint = streamKindHint(src, type)
      if (hint === "ts") {
        loadTs(src)
        return
      }
      if (hint === "hls") {
        loadHls(src)
        return
      }
      if (hint === "dash") {
        loadDash(src)
        return
      }
      if (hint === "native") {
        loadNative(src, type)
        return
      }
      // Unknown extension - probe and only load once we know the container
      destroyMpegts()
      destroyDash()
      try { player.reset() } catch {}
      probeContainer(src)
        .then((kind) => {
          if (pendingSrc !== src) return
          if (kind === "ts") loadTs(src)
          else if (kind === "dash") loadDash(src)
          else if (kind === "native") loadNative(src, type)
          else loadHls(src)
        })
        .catch(() => {
          if (pendingSrc !== src) return
          loadHls(src)
        })
    },
    play() {
      return player.play()
    },
    pause() {
      player.pause()
    },
    paused() {
      return player.paused?.() ?? true
    },
    muted(value) {
      if (value === undefined) return player.muted?.() ?? false
      player.muted(!!value)
      return undefined
    },
    reset() {
      pendingSrc = null
      destroyMpegts()
      destroyDash()
      try { player.reset() } catch {}
    },
    dispose() {
      pendingSrc = null
      destroyMpegts()
      destroyDash()
      try { player.dispose() } catch {}
    },
    duration() {
      const dur = player.duration?.()
      return Number.isFinite(dur) ? dur : 0
    },
    currentTime(value) {
      if (value === undefined) return player.currentTime?.() || 0
      player.currentTime(value)
      return value
    },
    on(event, fn) {
      player.on(event, fn)
    },
    off(event, fn) {
      player.off?.(event, fn)
    },
    one(event, fn) {
      player.one?.(event, fn)
    },
    el() {
      return player.el?.()
    },
    error() {
      return player.error?.() ?? null
    },
    requestFullscreen() {
      return player.requestFullscreen?.()
    },
    userActive(active) {
      try { player.userActive?.(active) } catch {}
    },
  }
  return wrapped
}

function mountNativePlayer(videoEl: HTMLVideoElement): VjsLikeHandle {
  let currentError: unknown = null

  const handle: VjsLikeHandle = {
    src({ src, type }) {
      currentError = null
      videoEl.pause()
      videoEl.removeAttribute("src")
      try { videoEl.load() } catch {}
      videoEl.preload = "auto"
      videoEl.playsInline = true
      const hint = streamKindHint(src, type)
      if (hint === "hls") {
        const canPlayNativeHls =
          videoEl.canPlayType("application/vnd.apple.mpegurl") ||
          videoEl.canPlayType("application/x-mpegURL")
        if (!canPlayNativeHls) {
          log.warn("[xt:player] native fallback received HLS without native HLS support")
        }
      }
      videoEl.src = src
      try { videoEl.load() } catch {}
    },
    play() {
      return videoEl.play()
    },
    pause() {
      videoEl.pause()
    },
    paused() {
      return videoEl.paused
    },
    muted(value) {
      if (value === undefined) return videoEl.muted
      videoEl.muted = !!value
      return undefined
    },
    reset() {
      currentError = null
      videoEl.pause()
      videoEl.removeAttribute("src")
      try { videoEl.load() } catch {}
    },
    dispose() {
      handle.reset?.()
    },
    duration() {
      return Number.isFinite(videoEl.duration) ? videoEl.duration : 0
    },
    currentTime(value) {
      if (value === undefined) return videoEl.currentTime || 0
      videoEl.currentTime = value
      return value
    },
    on(event, fn) {
      if (event === "error") {
        videoEl.addEventListener(event, (ev) => {
          currentError = videoEl.error || ev
          fn(ev)
        })
        return
      }
      videoEl.addEventListener(event, fn as EventListener)
    },
    off(event, fn) {
      videoEl.removeEventListener(event, fn as EventListener)
    },
    one(event, fn) {
      videoEl.addEventListener(event, fn as EventListener, { once: true })
    },
    el() {
      return videoEl
    },
    error() {
      return currentError || videoEl.error || null
    },
    requestFullscreen() {
      return videoEl.requestFullscreen?.()
    },
  }
  return handle
}

async function mountArtPlayer(videoEl: HTMLVideoElement): Promise<VjsLikeHandle> {
  const { default: Artplayer } = await import("artplayer")

  const parent = videoEl.parentElement
  if (!parent) {
    throw new Error("[xt:player] ArtPlayer mount: videoEl has no parent")
  }
  const container = document.createElement("div")
  container.id = videoEl.id
  container.className = videoEl.className
  for (const attr of Array.from(videoEl.attributes)) {
    if (attr.name === "id" || attr.name === "class") continue
    container.setAttribute(attr.name, attr.value)
  }
  container.style.width = "100%"
  container.style.height = "100%"
  parent.replaceChild(container, videoEl)

  let activeHls: { destroy: () => void } | null = null
  let activeMpegts: MpegtsHandle | null = null
  let activeDash: DashHandle | null = null
  let pendingSrc: string | null = null

  function destroyActiveEmbeddedHandles() {
    if (activeHls) {
      try { activeHls.destroy() } catch {}
      activeHls = null
    }
    if (activeMpegts) {
      try { activeMpegts.destroy() } catch {}
      activeMpegts = null
    }
    if (activeDash) {
      try { activeDash.destroy() } catch {}
      activeDash = null
    }
  }

  const art = new Artplayer({
    container,
    url: "",
    volume: 1,
    autoplay: false,
    autoSize: false,
    autoMini: false,
    setting: false,
    flip: false,
    pip: true,
    playbackRate: true,
    aspectRatio: false,
    fullscreen: true,
    fullscreenWeb: true,
    miniProgressBar: false,
    mutex: true,
    backdrop: false,
    playsInline: true,
    customType: {
      async m3u8(video, url) {
        destroyActiveEmbeddedHandles()
        if (
          video.canPlayType("application/vnd.apple.mpegurl") ||
          video.canPlayType("application/x-mpegURL")
        ) {
          video.src = url
          return
        }
        try {
          const { default: Hls } = await import("hls.js")
          if ((Hls as any).isSupported()) {
            const hls = new (Hls as any)({ enableWorker: true })
            hls.loadSource(url)
            hls.attachMedia(video)
            activeHls = hls
            return
          }
        } catch (error) {
          log.warn("[xt:player] hls.js import failed; falling back to <video src>", error)
        }
        log.warn("[xt:player] hls.js unsupported and no native HLS; fallback to <video src>")
        video.src = url
      },
      async ts(video, url) {
        destroyActiveEmbeddedHandles()
        const handle = await attachMpegts(video, url)
        if (!handle) {
          video.src = url
          return
        }
        if (pendingSrc !== url) {
          try { handle.destroy() } catch {}
          return
        }
        activeMpegts = handle
      },
      async mpd(video, url) {
        destroyActiveEmbeddedHandles()
        const handle = await attachDash(video, url)
        if (!handle) {
          video.src = url
          return
        }
        if (pendingSrc !== url) {
          try { handle.destroy() } catch {}
          return
        }
        activeDash = handle
      },
    },
  })

  art.on("destroy", () => {
    destroyActiveEmbeddedHandles()
  })

  const handle: VjsLikeHandle = {
    src({ src, type }) {
      pendingSrc = src
      destroyActiveEmbeddedHandles()
      const hint = streamKindHint(src, type)
      if (hint === "hls") {
        art.type = "m3u8"
        art.url = src
        return
      }
      if (hint === "ts") {
        art.type = "ts"
        art.url = src
        return
      }
      if (hint === "dash") {
        art.type = "mpd"
        art.url = src
        return
      }
      if (hint === "native") {
        art.type = ""
        art.url = src
        return
      }
      // Unknown - wait for the probe before loading anything so we don't
      // briefly hand a TS body to hls.js and trip MediaSource errors.
      art.url = ""
      probeContainer(src)
        .then((kind) => {
          if (pendingSrc !== src) return
          art.type = kind === "ts" ? "ts" : kind === "dash" ? "mpd" : kind === "native" ? "" : "m3u8"
          art.url = src
        })
        .catch(() => {
          if (pendingSrc !== src) return
          art.type = "m3u8"
          art.url = src
        })
    },
    play() {
      return art.play()
    },
    pause() {
      art.pause()
    },
    paused() {
      return art.video?.paused ?? true
    },
    muted(value) {
      if (value === undefined) return art.muted
      art.muted = !!value
      return undefined
    },
    reset() {
      pendingSrc = null
      destroyActiveEmbeddedHandles()
      art.url = ""
    },
    dispose() {
      pendingSrc = null
      destroyActiveEmbeddedHandles()
      try { art.destroy(false) } catch {}
    },
    duration() {
      const dur = art.duration
      return Number.isFinite(dur) ? dur : 0
    },
    currentTime(value) {
      if (value === undefined) return art.currentTime || 0
      art.currentTime = value
      return value
    },
    on(event, fn) {
      art.video?.addEventListener(event, fn as EventListener)
    },
    off(event, fn) {
      art.video?.removeEventListener(event, fn as EventListener)
    },
    one(event, fn) {
      art.video?.addEventListener(event, fn as EventListener, { once: true })
    },
    el() {
      return container
    },
    error() {
      return art.video?.error ?? null
    },
    requestFullscreen() {
      art.fullscreen = true
    },
  }
  return handle
}

// ---------------------------------------------------------------------------
// Mount entry point
// ---------------------------------------------------------------------------
export async function mountPlayer(
  videoEl: HTMLVideoElement,
  backend: PlayerBackend = getPlayerBackend(),
  options: MountOptions = {},
): Promise<Mounted> {
  if (backend === "artplayer" && isAndroid) backend = "videojs"
  if (backend === "mpv" || backend === "vlc") {
    if (!externalPlayersAvailable) {
      log.warn(`[xt:player] external backend "${backend}" requested but not available; falling back to artplayer`)
      try {
        document.dispatchEvent(
          new CustomEvent("xt:player-fallback", {
            detail: { requested: backend, used: "artplayer" },
          }),
        )
      } catch {}
      return mountPlayer(videoEl, "artplayer", options)
    }
    return {
      kind: "external",
      backend,
      launcher: getExternalLauncher(backend),
    }
  }
  if (backend === "videojs") {
    try {
      const handle = await mountVideoJs(videoEl, options)
      return {
        kind: "embedded",
        backend: "videojs",
        handle,
      }
    } catch (error) {
      log.warn("[xt:player] Video.js mount failed; falling back to native <video>", error)
      return {
        kind: "embedded",
        backend: "native",
        handle: mountNativePlayer(videoEl),
      }
    }
  }
  // artplayer (default)
  try {
    const handle = await mountArtPlayer(videoEl)
    return {
      kind: "embedded",
      backend: "artplayer",
      handle,
    }
  } catch (error) {
    log.warn("[xt:player] ArtPlayer mount failed; trying Video.js fallback", error)
    try {
      const handle = await mountVideoJs(videoEl, options)
      return {
        kind: "embedded",
        backend: "videojs",
        handle,
      }
    } catch (videoJsError) {
      log.warn("[xt:player] Video.js fallback failed; using native <video>", videoJsError)
      return {
        kind: "embedded",
        backend: "native",
        handle: mountNativePlayer(videoEl),
      }
    }
  }
}

export function isExternalBackend(backend: PlayerBackend): boolean {
  return EXTERNAL_PLAYER_BACKENDS.includes(backend as ExternalPlayerKind)
}
