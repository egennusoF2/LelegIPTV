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

import { log, redactUrl } from "@/scripts/lib/log.js"
import {
  getPlayerBackend,
  getPlayerPath,
  getPlayerExtraArgs,
  getPlayerReuseInstance,
  getUserAgent,
  EXTERNAL_PLAYER_BACKENDS,
} from "@/scripts/lib/app-settings.js"
import {
  preferPlainHttpForXtreamMedia,
  resolveEmbeddedStreamUrl,
  resolveHlsPlaybackUrl,
  resolveNativeStreamProxyUrl,
  isContainerUrl,
  isAppleEmbedded,
  isIosEmbedded,
  isTauriEmbedded,
  useDevStreamProxy,
  useNativeStreamProxy,
  unwrapStreamProxyUrl,
  wrapStreamUrlForDev,
} from "@/scripts/lib/stream-proxy"
import {
  shouldUseProviderFetchForMedia,
} from "@/scripts/lib/embedded-media-fetch"
import { toastError } from "@/scripts/lib/toast.js"
import {
  probeStreamKind,
  streamKindFromUrl,
  type StreamKind as ProbedStreamKind,
} from "@/scripts/lib/stream-probe.js"
import { shouldIgnoreContainerVideoError } from "@/scripts/lib/artplayer-track-settings.js"

export type PlayerBackend = "videojs" | "artplayer" | "mpv" | "vlc"
export type ExternalPlayerKind = "mpv" | "vlc"

export const RESUME_MIN_SECONDS_DEFAULT = 5

export interface VjsSrcOptions {
  src: string
  type: string
  /** Xtream `container_extension` — avoids blocking HLS probes for mkv/avi panels. */
  containerExtension?: string
  /** Remote URL for ffprobe when `src` is a local/downloaded file path */
  remoteSourceUrl?: string
  /** Seconds to start from when the native bridge has to recreate a non-seekable TS stream. */
  startSeconds?: number
  /** Real VOD duration from provider metadata; TS transcodes do not expose it reliably. */
  expectedDurationSeconds?: number
}

export interface VjsLikeHandle {
  src(opts: VjsSrcOptions): void
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

const VOD_PLACEHOLDER_EXTERNAL_COOLDOWN_MS = 12_000
const vodPlaceholderExternalLaunchAt = new Map<string, number>()

function defaultExternalPlayerPath(kind: ExternalPlayerKind): string {
  if (typeof navigator === "undefined") return ""
  const platform = navigator.platform || ""
  const ua = navigator.userAgent || ""
  const isMac = /^Mac/i.test(platform) || /\bMacintosh\b/i.test(ua)
  if (!isMac) return ""
  if (kind === "vlc") return "/Applications/VLC.app/Contents/MacOS/VLC"
  if (kind === "mpv") return "/opt/homebrew/bin/mpv"
  return ""
}

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
  const path = getPlayerPath(kind) || defaultExternalPlayerPath(kind)
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

async function tryExternalVodPlaceholderFallback(upstreamUrl: string): Promise<boolean> {
  if (!externalPlayersAvailable || !upstreamUrl) return false
  const now = Date.now()
  const last = vodPlaceholderExternalLaunchAt.get(upstreamUrl) || 0
  if (now - last < VOD_PLACEHOLDER_EXTERNAL_COOLDOWN_MS) return true
  vodPlaceholderExternalLaunchAt.set(upstreamUrl, now)

  const { resolveExternalVodAfterPlaceholder } = await import(
    "@/scripts/lib/embedded-vod-playback.js"
  )
  const externalUrl = await resolveExternalVodAfterPlaceholder(upstreamUrl)
  if (!externalUrl) {
    return false
  }

  for (const kind of EXTERNAL_PLAYER_BACKENDS as ExternalPlayerKind[]) {
    try {
      const launcher = getExternalLauncher(kind)
      await launcher.launch(externalUrl, {
        userAgent: getUserAgent() || null,
        referer: upstreamUrl,
      })
      log.info("[xt:player] VOD placeholder opened in external player", {
        kind,
        src: redactUrl(externalUrl).slice(0, 120),
      })
      return true
    } catch (error) {
      log.warn("[xt:player] VOD external placeholder fallback failed", {
        kind,
        error: String((error as Error)?.message || error),
      })
    }
  }
  return false
}

/**
 * Call the Rust `transcode_proxy_url` command to get a `/__transcode?url=…` loopback URL
 * that pipes the given upstream MKV through `ffmpeg -c copy -f mpegts`.
 * Returns null when running outside Tauri desktop, or when ffmpeg is not found.
 */
async function resolveTranscodeProxyUrl(
  mkvUrl: string,
  referer: string,
  audioIndex = 0,
  startSeconds = 0,
): Promise<string | null> {
  const { isTauriEmbedded, isIosEmbedded, resolveUpstreamUserAgent } = await import(
    "@/scripts/lib/stream-proxy.js"
  )
  if (!isTauriEmbedded() || isIosEmbedded()) return null
  try {
    const { invoke } = await import("@tauri-apps/api/core")
    return await invoke<string>("transcode_proxy_url", {
      url: mkvUrl,
      userAgent: resolveUpstreamUserAgent(mkvUrl) || null,
      referer: referer || null,
      audioIndex,
      startSeconds: Number.isFinite(startSeconds) ? Math.max(0, startSeconds) : null,
    })
  } catch (err) {
    log.warn("[xt:player] transcode_proxy_url invoke failed", err)
    return null
  }
}

function formatPlaybackClock(seconds: number): string {
  const safe = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0
  const h = Math.floor(safe / 3600)
  const m = Math.floor((safe % 3600) / 60)
  const s = safe % 60
  const mm = h > 0 ? String(m).padStart(2, "0") : String(m).padStart(2, "0")
  const ss = String(s).padStart(2, "0")
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`
}

/**
 * When the embedded player detects a placeholder VOD, ask Rust to remux the MKV sibling
 * through FFmpeg (-c copy -f mpegts) and hand the resulting MPEG-TS stream to mpegts.js —
 * exactly the same pattern as Megacubo's StreamerFFmpeg, without opening any external app.
 *
 * @param upstream   The original upstream URL (MP4 placeholder).
 * @param art        ArtPlayer instance.
 * @param beforeLoad Called with the final TS proxy URL just before art.url is set,
 *                   so the caller can update `pendingSrc` to match.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function retryEmbeddedVodWithMkv(
  upstream: string,
  art: any,
  beforeLoad?: (tsUrl: string) => void,
): Promise<boolean> {
  // NOTE: macOS block removed. transcode_proxy_url is registered for all Tauri desktop
  // platforms (macOS/Windows/Linux) and ffmpeg can be installed via Homebrew on macOS.
  // WKWebView fires MEDIA_ERR_SRC_NOT_SUPPORTED (code 4) immediately for MKV/AVI —
  // FFmpeg remux to MPEG-TS is the correct fallback path on all desktop platforms.
  const { resolveExternalVodAfterPlaceholder } = await import(
    "@/scripts/lib/embedded-vod-playback.js"
  )
  const mkvUrl = await resolveExternalVodAfterPlaceholder(upstream)
  if (!mkvUrl) return false

  const transcodeUrl = await resolveTranscodeProxyUrl(mkvUrl, upstream)
  if (!transcodeUrl) {
    log.warn("[xt:player] FFmpeg not available; MKV transcode skipped", {
      src: redactUrl(mkvUrl).slice(0, 120),
    })
    return false
  }

  log.info("[xt:player] VOD placeholder → FFmpeg remux MKV→TS in embedded player", {
    src: redactUrl(mkvUrl).slice(0, 120),
  })
  // Store the original MKV URL so the `ts` customType can probe tracks from it
  art._xtTranscodeSrcUrl = mkvUrl
  // Update pendingSrc BEFORE setting art.url so the `ts` customType pendingSrc check passes
  beforeLoad?.(transcodeUrl)
  setArtplayerLoading(art, true)
  art.type = "ts"
  art.url = transcodeUrl
  return true
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

const NATIVE_CONTAINER_RE =
  /\.(mkv|mp4|avi|webm|mov|m4v|m4a|mp3|flac|ogg)(\?|#|$)/i

/** ArtPlayer `customType` key for direct `<video src>` (MKV/MP4 via proxy). */
function artplayerTypeForUrl(
  url: string,
  hint: StreamKind | "unknown",
): string {
  if (hint === "hls") return "m3u8"
  if (hint === "ts") return "ts"
  if (hint === "dash") return "mpd"
  const path = url.split("?")[0] || url
  if (hint === "native" || NATIVE_CONTAINER_RE.test(path)) return "xt-native"
  return "m3u8"
}

function streamKindHint(src: string, type?: string): StreamKind | "unknown" {
  return normalizeProbedKind(streamKindFromUrl(src, type))
}

function normalizeProbedKind(kind: ProbedStreamKind | "unknown"): StreamKind | "unknown" {
  return kind === "hls-vod" ? "hls" : kind
}

async function probeContainer(src: string): Promise<StreamKind> {
  const kind = normalizeProbedKind(await probeStreamKind(src))
  return kind === "unknown" ? "hls" : kind
}

function setArtplayerLoading(art: { loading?: { show: boolean } }, show: boolean): void {
  try {
    if (art.loading) art.loading.show = show
  } catch {}
}

function emitPlayerDebug(message: string, data?: unknown): void {
  try {
    document.dispatchEvent(
      new CustomEvent("xt:player-debug", {
        detail: { message, data },
      }),
    )
  } catch {}
}

async function resolveArtNativePlayUrl(playUrl: string): Promise<string> {
  const normalized = preferPlainHttpForXtreamMedia(playUrl)
  if (useNativeStreamProxy()) {
    return resolveNativeStreamProxyUrl(normalized)
  }
  return resolveEmbeddedStreamUrl(normalized)
}

function wireArtLoadingUntilPlay(art: {
  loading?: { show: boolean }
  video?: HTMLVideoElement
}): void {
  setArtplayerLoading(art, true)
  const video = art.video
  if (!video) return
  const hide = () => setArtplayerLoading(art, false)
  video.addEventListener("playing", hide, { once: true })
  video.addEventListener("canplay", hide, { once: true })
  video.addEventListener("error", hide, { once: true })
}

interface MpegtsHandle {
  destroy: () => void
}

interface DashHandle {
  destroy: () => void
}

interface ShakaHandle {
  destroy: () => Promise<void> | void
}

/** Shaka is opt-in only; web VOD defaults to hls.js per playback guidelines. */
export function shouldUseShakaForAdaptive(
  kind: StreamKind | "unknown",
  isLive: boolean,
): boolean {
  if (kind !== "hls" && kind !== "dash") return false
  if (isLive) return false
  try {
    const params = new URLSearchParams(window.location.search)
    if (params.get("shaka") === "1") return true
    if (localStorage.getItem("xt_use_shaka") === "1") return true
  } catch {}
  return false
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
  opts: { live?: boolean; durationSeconds?: number } = {},
): Promise<MpegtsHandle | null> {
  emitPlayerDebug("mpegts import start", { url })
  const mpegtsMod = await import("mpegts.js")
  const mpegts = (mpegtsMod as any).default || mpegtsMod
  emitPlayerDebug("mpegts import ok", {
    supported: Boolean(mpegts?.isSupported?.()),
    url,
  })
  if (!mpegts?.isSupported?.()) {
    log.warn("[xt:player] mpegts.js unsupported in this WebView")
    return null
  }
  const { createEmbeddedMpegtsConfig } = await import(
    "@/scripts/lib/embedded-media-fetch.js"
  )
  const extraConfig = await createEmbeddedMpegtsConfig({ live: opts.live })
  const dataSource: Record<string, unknown> = {
      type: "mpegts",
      isLive: opts.live !== false,
      url,
    }
  if (Number.isFinite(opts.durationSeconds) && Number(opts.durationSeconds) > 0) {
    dataSource.duration = Math.floor(Number(opts.durationSeconds) * 1000)
  }
  const player = mpegts.createPlayer(
    dataSource,
    extraConfig,
  )
  const Events = mpegts.Events
  log.info("[xt:player] mpegts attach", {
    live: opts.live !== false,
    durationSeconds: opts.durationSeconds || 0,
    url: redactUrl(url).slice(0, 160),
  })
  if (Events?.MEDIA_INFO) {
    player.on(Events.MEDIA_INFO, (info: { audioCodec?: string }) => {
      log.info("[xt:player] mpegts media info", info)
      try {
        window.dispatchEvent(new CustomEvent("xt:mpegts-media-ready"))
      } catch {}
      import("@/scripts/lib/embedded-hls-audio.js").then(({ notifyIfMpegtsAudioCodecUnsupported }) => {
        notifyIfMpegtsAudioCodecUnsupported(info?.audioCodec || "")
      })
    })
  }
  if (Events?.STATISTICS_INFO) {
    let loggedStats = false
    player.on(Events.STATISTICS_INFO, (info: unknown) => {
      if (loggedStats) return
      loggedStats = true
      log.info("[xt:player] mpegts first stats", info)
    })
  }
  if (Events?.ERROR) {
    player.on(Events.ERROR, (errorType: string, errorDetail: unknown) => {
      log.warn("[xt:player] mpegts error", { url, errorType, errorDetail })
      try {
        window.dispatchEvent(
          new CustomEvent("xt:mpegts-playback-error", {
            detail: { url, errorType, errorDetail },
          }),
        )
      } catch {}
    })
  }
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
  let activeHls: { destroy: () => void } | null = null
  let pendingSrc: string | null = null
  let clearVodPlaceholderGuard: (() => void) | null = null
  const isLivePlayback = options.liveui ?? false

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

  function destroyHls() {
    if (activeHls) {
      try { activeHls.destroy() } catch {}
      activeHls = null
    }
  }

  async function loadHls(src: string) {
    destroyMpegts()
    destroyDash()
    destroyHls()
    try { player.pause?.() } catch {}
    try { player.reset() } catch {}
    const videoElement = getUnderlyingVideo()
    const resolved = await resolveHlsPlaybackUrl(src)
    const { shouldUseHlsJsForM3u8 } = await import("@/scripts/lib/stream-proxy.js")
    if (!shouldUseHlsJsForM3u8({ live: isLivePlayback })) {
      player.src({ src: resolved, type: "application/x-mpegURL" })
      return
    }
    if (!videoElement) {
      player.src({ src: resolved, type: "application/x-mpegURL" })
      return
    }
    try {
      const { default: Hls } = await import("hls.js")
      if (!(Hls as any).isSupported?.()) {
        player.src({ src: resolved, type: "application/x-mpegURL" })
        return
      }
      const { createEmbeddedHlsConfig } = await import(
        "@/scripts/lib/embedded-media-fetch.js"
      )
      const { ensureVideoAudible } = await import(
        "@/scripts/lib/embedded-hls-audio.js"
      )
      const { wireHlsForVideojs } = await import(
        "@/scripts/lib/embedded-videojs-hls-tracks.js"
      )
      const hlsConfig = await createEmbeddedHlsConfig({ live: isLivePlayback })
      const hls = new (Hls as any)(hlsConfig)
      wireHlsForVideojs(player, hls, videoElement, { live: isLivePlayback })
      hls.loadSource(resolved)
      hls.attachMedia(videoElement)
      ensureVideoAudible(videoElement, null)
      const HlsEvents = (Hls as any).Events
      if (HlsEvents?.ERROR) {
        hls.on(HlsEvents.ERROR, (_event: string, data: { fatal?: boolean }) => {
          if (data?.fatal) {
            log.warn("[xt:player] Video.js hls.js fatal error", { src: redactUrl(src) })
          }
        })
      }
      if (pendingSrc !== src) {
        try { hls.destroy() } catch {}
        return
      }
      activeHls = hls
      try { player.hasStarted?.(true) } catch {}
    } catch (error) {
      log.warn("[xt:player] Video.js hls.js failed; falling back to VHS src", error)
      player.src({ src: resolved, type: "application/x-mpegURL" })
    }
  }

  function loadNative(src: string, type?: string) {
    destroyMpegts()
    destroyDash()
    destroyHls()
    clearVodPlaceholderGuard?.()
    clearVodPlaceholderGuard = null
    player.src({ src, type: type || "video/mp4" })
    if (!isLivePlayback && isTauriEmbedded()) {
      const upstream = unwrapStreamProxyUrl(src)
      void import("@/scripts/lib/embedded-vod-playback.js").then(
        ({ wireVodPlaceholderGuard }) => {
          if (pendingSrc !== src) return
          clearVodPlaceholderGuard?.()
          clearVodPlaceholderGuard = wireVodPlaceholderGuard(
            getUnderlyingVideo(),
            upstream,
            async () => {
              try { player.reset() } catch {}
              const { resolveExternalVodAfterPlaceholder } = await import(
                "@/scripts/lib/embedded-vod-playback.js"
              )
              const mkvUrl = await resolveExternalVodAfterPlaceholder(upstream)
              if (mkvUrl) {
                const transcodeUrl = await resolveTranscodeProxyUrl(mkvUrl, upstream)
                if (transcodeUrl) {
                  log.info("[xt:player] VOD placeholder → FFmpeg remux MKV→TS (Video.js)", {
                    src: redactUrl(mkvUrl).slice(0, 120),
                  })
                  destroyMpegts()
                  const videoEl = getUnderlyingVideo()
                  if (videoEl) {
                    const handle = await attachMpegts(videoEl, transcodeUrl)
                    if (handle) {
                      activeMpegts = handle
                      try { player.hasStarted?.(true) } catch {}
                      videoEl.play?.().catch(() => {})
                      return
                    }
                  }
                }
              }
              if (!(await tryExternalVodPlaceholderFallback(upstream))) {
                toastError(
                  "This stream looks like a provider placeholder clip. Install ffmpeg (brew install ffmpeg) or use MPV/VLC in Settings → Playback.",
                  { duration: 11000 },
                )
              }
            },
          )
        },
      )
    }
  }

  async function loadNativeChecked(src: string, type?: string) {
    if (!isLivePlayback && isTauriEmbedded()) {
      const upstream = unwrapStreamProxyUrl(src)
      const { canPlayVodNativeOnTauri } = await import(
        "@/scripts/lib/embedded-vod-playback.js"
      )
      if (!(await canPlayVodNativeOnTauri(upstream))) {
        log.warn("[xt:player] VOD native playback blocked", {
          src: redactUrl(upstream).slice(0, 120),
        })
        try { player.reset() } catch {}
        const { resolveExternalVodAfterPlaceholder } = await import(
          "@/scripts/lib/embedded-vod-playback.js"
        )
        const mkvUrl = await resolveExternalVodAfterPlaceholder(upstream)
        if (mkvUrl) {
          const transcodeUrl = await resolveTranscodeProxyUrl(mkvUrl, upstream)
          if (transcodeUrl) {
            log.info("[xt:player] blocked VOD → FFmpeg remux MKV→TS (Video.js)", {
              src: redactUrl(mkvUrl).slice(0, 120),
            })
            destroyMpegts()
            const videoEl = getUnderlyingVideo()
            if (videoEl) {
              const handle = await attachMpegts(videoEl, transcodeUrl)
              if (handle) {
                activeMpegts = handle
                try { player.hasStarted?.(true) } catch {}
                videoEl.play?.().catch(() => {})
                return
              }
            }
          }
        }
        if (!(await tryExternalVodPlaceholderFallback(upstream))) {
          toastError(
            "This title cannot play in the embedded player. Install ffmpeg (brew install ffmpeg) or use MPV/VLC in Settings → Playback.",
            { duration: 11000 },
          )
        }
        return
      }
    }
    loadNative(src, type)
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
    let playUrl = preferPlainHttpForXtreamMedia(unwrapStreamProxyUrl(src))
    // Continuous MPEG-TS must hit the upstream URL via providerFetch (custom loader).
    // The loopback /__stream proxy is for HLS segments and breaks mpegts.js live reads.
    if (useDevStreamProxy()) {
      playUrl = wrapStreamUrlForDev(playUrl)
    } else if (useNativeStreamProxy() && !shouldUseProviderFetchForMedia()) {
      try {
        playUrl = await resolveNativeStreamProxyUrl(playUrl)
      } catch (err) {
        log.warn("[xt:player] TS proxy resolve failed; using direct URL", err)
      }
    }
    const videoElement = getUnderlyingVideo()
    if (!videoElement) {
      loadHls(playUrl)
      return
    }
    const handle = await attachMpegts(videoElement, playUrl)
    if (!handle) {
      loadHls(playUrl)
      return
    }
    if (pendingSrc !== src) {
      try { handle.destroy() } catch {}
      return
    }
    activeMpegts = handle
    try { player.hasStarted?.(true) } catch {}
    try {
      const videoEl = getUnderlyingVideo()
      const playPromise = videoEl?.play?.()
      if (playPromise && typeof playPromise.catch === "function") {
        playPromise.catch(() => {})
      }
    } catch {}
    try {
      const playPromise = player.play?.()
      if (playPromise && typeof playPromise.catch === "function") {
        playPromise.catch(() => {})
      }
    } catch {}
  }

  function loadFromResolvedUrl(playUrl: string, type?: string) {
    const hint = streamKindHint(playUrl, type)
    if (hint === "ts") {
      loadTs(playUrl)
      return
    }
    if (hint === "hls") {
      void loadHls(playUrl)
      return
    }
    if (hint === "dash") {
      loadDash(playUrl)
      return
    }
    if (hint === "native") {
      void loadNativeChecked(playUrl, type)
      return
    }
    destroyMpegts()
    destroyDash()
    try { player.reset() } catch {}
    probeContainer(playUrl)
      .then((kind) => {
        if (pendingSrc !== playUrl) return
        if (kind === "ts") loadTs(playUrl)
        else if (kind === "dash") loadDash(playUrl)
        else if (kind === "native") void loadNativeChecked(playUrl, type)
        else void loadHls(playUrl)
      })
      .catch(() => {
        if (pendingSrc !== playUrl) return
        void loadHls(playUrl)
      })
  }

  const wrapped: VjsLikeHandle = {
    src({ src, type, containerExtension }) {
      pendingSrc = src
      void (async () => {
        const {
          preferVodHlsUrl,
          containerExtensionFromUrl,
          shouldSkipVodHlsProbe,
          isXtreamVodContainerUrl,
        } = await import("@/scripts/lib/embedded-vod-playback.js")
        const ext = containerExtension || containerExtensionFromUrl(src)
        const normalized = preferPlainHttpForXtreamMedia(src)
        const isVod = !(options.liveui ?? false)

        if (isVod && isXtreamVodContainerUrl(normalized)) {
          // WKWebView on macOS cannot play MKV; probe MP4/HLS before assigning <video>.
          if (!isTauriEmbedded()) {
            const quickUrl = await resolveArtNativePlayUrl(normalized)
            if (pendingSrc !== src) return
            pendingSrc = quickUrl
            loadNative(quickUrl, type)
            if (!shouldSkipVodHlsProbe(normalized, ext)) {
              const playUrl = await preferVodHlsUrl(src, { containerExtension: ext })
              if (pendingSrc !== quickUrl && pendingSrc !== src) return
              if (playUrl !== normalized && playUrl !== src) {
                pendingSrc = playUrl
                loadFromResolvedUrl(playUrl, type)
              }
            }
            return
          }
          const playUrl = await preferVodHlsUrl(src, { containerExtension: ext })
          if (pendingSrc !== src) return
          pendingSrc = playUrl
          if (streamKindHint(playUrl, type) === "native") {
            const resolvedNativeUrl = await resolveArtNativePlayUrl(playUrl)
            if (pendingSrc !== src) return
            pendingSrc = resolvedNativeUrl
            loadNativeChecked(resolvedNativeUrl, type)
            return
          }
          loadFromResolvedUrl(playUrl, type)
          return
        }

        let playUrl = src
        if (isVod) {
          playUrl = await preferVodHlsUrl(src, { containerExtension: ext })
        }
        if (pendingSrc !== src) return
        if (streamKindHint(playUrl, type) === "native") {
          const resolvedNativeUrl = await resolveArtNativePlayUrl(playUrl)
          if (pendingSrc !== src) return
          pendingSrc = resolvedNativeUrl
          await loadNativeChecked(resolvedNativeUrl, type)
          return
        }
        pendingSrc = playUrl
        loadFromResolvedUrl(playUrl, type)
      })()
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
      destroyHls()
      try { player.reset() } catch {}
    },
    dispose() {
      pendingSrc = null
      destroyMpegts()
      destroyDash()
      destroyHls()
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

async function mountArtPlayer(
  videoEl: HTMLVideoElement,
  options: MountOptions = {},
): Promise<VjsLikeHandle> {
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
  let activeShaka: ShakaHandle | null = null
  let pendingSrc: string | null = null
  let pendingVodFallbackUrl: string | null = null
  let pendingLoad: Promise<void> | null = null
  let loadGeneration = 0

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
    if (activeShaka) {
      try { void activeShaka.destroy() } catch {}
      activeShaka = null
    }
  }

  const isLive = options.liveui === true

  const art = new Artplayer({
    container,
    url: "",
    volume: 1,
    autoplay: false,
    autoSize: false,
    autoMini: false,
    setting: true,
    isLive,
    flip: false,
    pip: true,
    playbackRate: !isLive,
    aspectRatio: false,
    fullscreen: true,
    fullscreenWeb: true,
    miniProgressBar: !isLive,
    mutex: true,
    contextmenu: [],
    backdrop: false,
    playsInline: true,
    subtitle: {
      url: "",
      type: "vtt",
    },
    customType: {
      async "xt-native"(video, url) {
        destroyActiveEmbeddedHandles()
        art.hls = null
        const { bootstrapArtplayerSubtitleTrack } = await import(
          "@/scripts/lib/embedded-container-tracks.js"
        )
        bootstrapArtplayerSubtitleTrack(art, video)
        const { wireVodPlaceholderGuard, canPlayVodNativeOnTauri } = await import(
          "@/scripts/lib/embedded-vod-playback.js"
        )
        const upstream = unwrapStreamProxyUrl(url)

        // Shared fallback handler used both by the placeholder guard AND the
        // MEDIA_ERR_SRC_NOT_SUPPORTED (code 4) error handler below.
        const triggerFfmpegFallback = async () => {
          try { video.pause() } catch {}
          video.removeAttribute("src")
          setArtplayerLoading(art, true)
          if (await retryEmbeddedVodWithMkv(upstream, art, (u) => { pendingSrc = u })) return
          setArtplayerLoading(art, false)
          if (!(await tryExternalVodPlaceholderFallback(upstream))) {
            toastError(
              "This title cannot play in the embedded player. Install ffmpeg (brew install ffmpeg) to play MKV/AVI in-app, or use MPV/VLC in Settings → Playback.",
              { duration: 11000 },
            )
          }
        }

        // macOS (and other Tauri desktops) fire MEDIA_ERR_SRC_NOT_SUPPORTED (code 4)
        // immediately when video.src is a container format AVFoundation/WebKit cannot
        // play (MKV, AVI, WMV…). The placeholder guard only listens to loadedmetadata,
        // so without this error listener the video would silently stay blank.
        const onVideoError = () => {
          if (video.error?.code === 4 /* MEDIA_ERR_SRC_NOT_SUPPORTED */) {
            log.warn("[xt:player] xt-native MEDIA_ERR_SRC_NOT_SUPPORTED → FFmpeg fallback", {
              src: redactUrl(upstream).slice(0, 120),
            })
            void triggerFfmpegFallback()
          }
        }
        video.addEventListener("error", onVideoError, { once: true })

        art._xtClearVodGuard?.()
        art._xtClearVodGuard = wireVodPlaceholderGuard(video, upstream, async () => {
          video.removeEventListener("error", onVideoError)
          await triggerFfmpegFallback()
        })

        // For known non-playable containers on Tauri desktop (MKV, AVI…),
        // skip video.src entirely and go straight to FFmpeg transcode.
        if (isTauriEmbedded() && !isIosEmbedded() && !(await canPlayVodNativeOnTauri(upstream))) {
          log.info("[xt:player] xt-native: container not playable natively → FFmpeg directly", {
            src: redactUrl(upstream).slice(0, 120),
          })
          video.removeEventListener("error", onVideoError)
          art._xtClearVodGuard?.()
          art._xtClearVodGuard = null
          await triggerFfmpegFallback()
          return
        }

        video.src = url
        try {
          video.load()
        } catch {}
      },
      async m3u8(video, url) {
        destroyActiveEmbeddedHandles()

        // iOS fast path — MUST run before any `await` to keep the user-gesture
        // activation context alive (WKWebView invalidates it in one microtask turn).
        // `url` is already fully proxy-resolved by loadArtSrc, no further work needed.
        if (isIosEmbedded()) {
          video.playsInline = true
          video.src = url
          try { video.load() } catch {}
          return
        }

        const vodFallbackUrl = !isLive ? pendingVodFallbackUrl : null
        const { isVodHlsDenied } = await import(
          "@/scripts/lib/embedded-vod-playback.js"
        )
        const { unwrapStreamProxyUrl } = await import(
          "@/scripts/lib/stream-proxy.js"
        )
        const fallbackToVodContainer = async () => {
          if (!vodFallbackUrl || isLive) return false
          const upstream = unwrapStreamProxyUrl(vodFallbackUrl)
          const { canPlayVodNativeOnTauri, wireVodPlaceholderGuard } = await import(
            "@/scripts/lib/embedded-vod-playback.js"
          )
          if (!(await canPlayVodNativeOnTauri(upstream))) {
            log.warn("[xt:player] HLS VOD fallback blocked (placeholder/unsupported)", {
              fallback: redactUrl(upstream).slice(0, 120),
            })
            setArtplayerLoading(art, false)
            if (await retryEmbeddedVodWithMkv(upstream, art, (url) => { pendingSrc = url })) return true
            if (!(await tryExternalVodPlaceholderFallback(upstream))) {
              toastError(
                "This title cannot play in the embedded player. Install ffmpeg (brew install ffmpeg) or use MPV/VLC in Settings → Playback.",
                { duration: 11000 },
              )
            }
            return true
          }
          log.debug("[xt:player] HLS VOD failed; falling back to container", {
            hls: redactUrl(url).slice(0, 120),
            fallback: redactUrl(vodFallbackUrl).slice(0, 120),
          })
          destroyActiveEmbeddedHandles()
          art.hls = null
          art._xtClearVodGuard?.()
          art._xtClearVodGuard = wireVodPlaceholderGuard(video, upstream, async () => {
            try { video.pause() } catch {}
            video.removeAttribute("src")
            setArtplayerLoading(art, true)
            if (await retryEmbeddedVodWithMkv(upstream, art, (url) => { pendingSrc = url })) return
            setArtplayerLoading(art, false)
            if (!(await tryExternalVodPlaceholderFallback(upstream))) {
              toastError(
                "This stream looks like a provider placeholder clip. Install ffmpeg (brew install ffmpeg) or use MPV/VLC in Settings → Playback.",
                { duration: 11000 },
              )
            }
          })
          video.src = vodFallbackUrl
          try {
            video.load()
          } catch {}
          return true
        }
        if (
          !isLive &&
          vodFallbackUrl &&
          isVodHlsDenied(unwrapStreamProxyUrl(url))
        ) {
          if (await fallbackToVodContainer()) return
        }
        const { shouldUseHlsJsForM3u8 } = await import(
          "@/scripts/lib/stream-proxy.js"
        )
        if (shouldUseShakaForAdaptive("hls", isLive)) {
          try {
            const { attachShaka } = await import("@/scripts/lib/embedded-shaka-tracks.js")
            const { resolveEmbeddedStreamUrl } = await import(
              "@/scripts/lib/embedded-media-fetch.js"
            )
            activeShaka = await attachShaka(art, video, url, { live: isLive })
            return
          } catch (error) {
            log.warn("[xt:player] Shaka HLS failed; falling back to hls.js", error)
            if (await fallbackToVodContainer()) return
          }
        }
        if (!shouldUseHlsJsForM3u8({ live: isLive })) {
          video.src = url
          video.addEventListener(
            "error",
            () => {
              void fallbackToVodContainer()
            },
            { once: true },
          )
          return
        }
        try {
          const { default: Hls } = await import("hls.js")
          if ((Hls as any).isSupported()) {
            const { createEmbeddedHlsConfig } = await import(
              "@/scripts/lib/embedded-media-fetch.js"
            )
            const hlsConfig = await createEmbeddedHlsConfig({ live: isLive })
            const hls = new (Hls as any)(hlsConfig)
            const { wireHlsForArtplayer } = await import(
              "@/scripts/lib/embedded-hls-tracks.js"
            )
            const { ensureVideoAudible } = await import(
              "@/scripts/lib/embedded-hls-audio.js"
            )
            wireHlsForArtplayer(art, hls, video, { live: isLive })
            const HlsEvents = (Hls as any).Events
            log.info("[xt:player] hls attach", {
              live: isLive,
              url: redactUrl(url).slice(0, 160),
            })
            if (HlsEvents?.MANIFEST_PARSED) {
              hls.on(HlsEvents.MANIFEST_PARSED, (_event: string, data: any) => {
                log.info("[xt:player] hls manifest parsed", {
                  levels: data?.levels?.length ?? 0,
                  audioTracks: data?.audioTracks?.length ?? 0,
                  subtitleTracks: data?.subtitleTracks?.length ?? 0,
                  url: redactUrl(url).slice(0, 120),
                })
              })
            }
            if (HlsEvents?.FRAG_LOADED) {
              let loggedFirstFragment = false
              hls.on(HlsEvents.FRAG_LOADED, (_event: string, data: any) => {
                if (loggedFirstFragment) return
                loggedFirstFragment = true
                log.info("[xt:player] hls first fragment loaded", {
                  sn: data?.frag?.sn,
                  type: data?.frag?.type,
                  url: redactUrl(data?.frag?.url || "").slice(0, 120),
                })
              })
            }
            if (HlsEvents?.ERROR) {
              hls.on(HlsEvents.ERROR, (_event: string, data: any) => {
                log.warn("[xt:player] hls error", {
                  fatal: data?.fatal,
                  type: data?.type,
                  details: data?.details,
                  url: redactUrl(data?.url || data?.frag?.url || "").slice(0, 120),
                })
                if (data?.fatal) void fallbackToVodContainer()
              })
            }
            hls.loadSource(url)
            hls.attachMedia(video)
            art.volume = 1
            art.muted = false
            ensureVideoAudible(video, art)
            activeHls = hls
            return
          }
        } catch (error) {
          log.warn("[xt:player] hls.js import failed; falling back to <video src>", error)
        }
        if (await fallbackToVodContainer()) return
        log.warn("[xt:player] hls.js unsupported and no native HLS; fallback to <video src>")
        video.src = url
      },
      async ts(video, url) {
        emitPlayerDebug("customType ts entered", {
          url,
          pendingSrc,
          expectedDurationSeconds: art._xtExpectedDurationSeconds,
        })
        destroyActiveEmbeddedHandles()
        art._xtVirtualTimelineInstalled = url.includes("/__transcode")
        let handle: MpegtsHandle | null = null
        try {
          handle = await attachMpegts(video, url, {
            live: !url.includes("/__transcode"),
            durationSeconds: art._xtExpectedDurationSeconds,
          })
        } catch (error) {
          emitPlayerDebug("customType ts attach failed", {
            error: String((error as Error)?.message || error),
            url,
          })
          log.warn("[xt:player] mpegts attach failed", error)
          setArtplayerLoading(art, false)
        }
        if (!handle) {
          emitPlayerDebug("customType ts fallback to video.src", { url })
          video.src = url
          return
        }
        // Loopback transcode URLs (/__transcode) are always intentional redirects from the
        // placeholder-fallback path; ArtPlayer may normalize the URL string slightly, so
        // skip the pendingSrc equality check for them to avoid silently destroying the handle.
        const isTranscodeUrl = url.includes("/__transcode")
        if (!isTranscodeUrl && pendingSrc !== url) {
          emitPlayerDebug("customType ts discarded stale handle", { pendingSrc, url })
          try { handle.destroy() } catch {}
          return
        }
        activeMpegts = handle
        emitPlayerDebug("customType ts attached", { url })
        setArtplayerLoading(art, false)
        // Track/subtitle probing for the transcode path: probe from the original MKV URL.
        // Release Tauri uses the native loopback proxy; dev uses the Vite proxy.
        const containerSrc = typeof art._xtTranscodeSrcUrl === "string"
          ? art._xtTranscodeSrcUrl as string
          : null
        if (containerSrc) {
          art._xtContainerSourceUrl = containerSrc
          void import("@/scripts/lib/stream-proxy.js").then(({ useDevStreamProxy, useNativeStreamProxy }) => {
            if (!useDevStreamProxy() && !useNativeStreamProxy()) return
            return import("@/scripts/lib/embedded-container-tracks.js").then(
              ({ bootstrapArtplayerSubtitleTrack, attachContainerTracksForArtplayer }) => {
                bootstrapArtplayerSubtitleTrack(art, video)
                return attachContainerTracksForArtplayer(art, containerSrc)
              },
            )
          })
        }
      },
      async mpd(video, url) {
        destroyActiveEmbeddedHandles()
        if (shouldUseShakaForAdaptive("dash", isLive)) {
          try {
            const { attachShaka } = await import("@/scripts/lib/embedded-shaka-tracks.js")
            activeShaka = await attachShaka(art, video, url, { live: isLive })
            return
          } catch (error) {
            log.warn("[xt:player] Shaka DASH failed; falling back to dash.js", error)
          }
        }
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
    art.hls = null
    art._xtVirtualTimelineInstalled = false
  })
  try {
    ;(window as any).__xtLastArt = art
  } catch {}

  function virtualVodDuration(): number {
    return Number.isFinite(art._xtExpectedDurationSeconds) &&
      Number(art._xtExpectedDurationSeconds) > 0
      ? Number(art._xtExpectedDurationSeconds)
      : 0
  }

  function virtualVodCurrentTime(): number {
    const offset =
      Number.isFinite(art._xtPlaybackOffsetSeconds)
        ? Math.max(0, Number(art._xtPlaybackOffsetSeconds))
        : 0
    const local =
      art.video && Number.isFinite(art.video.currentTime)
        ? Math.max(0, Number(art.video.currentTime))
        : 0
    const duration = virtualVodDuration()
    return duration > 0 ? Math.min(duration, offset + local) : offset + local
  }

  function isVirtualVodTimelineActive(): boolean {
    if (!art._xtVirtualTimelineInstalled) return false
    if (virtualVodDuration() <= 0) return false
    const url =
      (art.video as HTMLVideoElement | undefined)?.currentSrc ||
      (art.video as HTMLVideoElement | undefined)?.src ||
      (typeof art.url === "string" ? art.url : "")
    return /\/__transcode(?:\?|$)/i.test(url)
  }

  async function restartVirtualVodAt(seconds: number): Promise<void> {
    const source =
      (typeof art._xtTranscodeSrcUrl === "string" && art._xtTranscodeSrcUrl) ||
      (typeof art._xtContainerSourceUrl === "string" && art._xtContainerSourceUrl) ||
      (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
      ""
    const duration = virtualVodDuration()
    if (!source || duration <= 0) return
    const target = Math.min(Math.max(0, seconds), Math.max(0, duration - 1))
    const audioIndex =
      Number.isFinite(art._xtContainerAudioIndex)
        ? Math.max(0, Math.floor(Number(art._xtContainerAudioIndex)))
        : 0
    const referer = (() => {
      try {
        return `${new URL(source).origin}/`
      } catch {
        return ""
      }
    })()
    const shouldResume = !art.video || !art.video.paused
    log.info("[xt:player] virtual VOD seek", {
      target,
      audioIndex,
      source: redactUrl(source).slice(0, 120),
    })
    setArtplayerLoading(art, true)
    destroyActiveEmbeddedHandles()
    const transcodeUrl = await resolveTranscodeProxyUrl(source, referer, audioIndex, target)
    if (!transcodeUrl) {
      setArtplayerLoading(art, false)
      return
    }
    pendingSrc = transcodeUrl
    art._xtTranscodeSrcUrl = source
    art._xtContainerSourceUrl = source
    art._xtPlaybackOffsetSeconds = target
    art._xtVirtualTimelineInstalled = true
    art.type = "ts"
    art.url = transcodeUrl
    if (shouldResume) {
      const resume = () => {
        try {
          const p = art.play?.()
          if (p && typeof p.catch === "function") p.catch(() => {})
        } catch {}
      }
      art.once?.("video:canplay", resume)
      art.once?.("video:loadeddata", resume)
    }
    updateVirtualVodUi()
  }

  art._xtRestartTranscodeAt = restartVirtualVodAt

  function updateVirtualVodUi(): void {
    if (!isVirtualVodTimelineActive()) return
    const duration = virtualVodDuration()
    const current = virtualVodCurrentTime()
    const pct = duration > 0 ? Math.min(1, Math.max(0, current / duration)) : 0
    const $progress = art.template?.$progress as HTMLElement | undefined
    const $played = $progress?.querySelector(".art-progress-played") as HTMLElement | null
    const $loaded = $progress?.querySelector(".art-progress-loaded") as HTMLElement | null
    const $indicator = $progress?.querySelector(".art-progress-indicator") as HTMLElement | null
    if ($played) $played.style.width = `${pct * 100}%`
    if ($loaded) $loaded.style.width = "100%"
    if ($indicator) $indicator.style.left = `${pct * 100}%`
    const label = `${formatPlaybackClock(current)} / ${formatPlaybackClock(duration)}`
    const left = art.template?.$controlsLeft as HTMLElement | undefined
    const controls = left ? Array.from(left.querySelectorAll<HTMLElement>(".art-control")) : []
    const timeControl = controls.find((el) => /\d{1,2}:\d{2}\s*\/\s*\d{1,2}:\d{2}/.test(el.textContent || ""))
    if (timeControl && timeControl.textContent !== label) {
      timeControl.textContent = label
    }
  }

  function seekVirtualVodFromEvent(event: MouseEvent | TouchEvent): void {
    if (!isVirtualVodTimelineActive()) return
    const $progress = art.template?.$progress as HTMLElement | undefined
    const duration = virtualVodDuration()
    if (!$progress || duration <= 0) return
    const rect = $progress.getBoundingClientRect()
    const clientX =
      "touches" in event && event.touches.length > 0
        ? event.touches[0]!.clientX
        : "changedTouches" in event && event.changedTouches.length > 0
          ? event.changedTouches[0]!.clientX
          : (event as MouseEvent).clientX
    const pct = Math.min(1, Math.max(0, (clientX - rect.left) / Math.max(1, rect.width)))
    void restartVirtualVodAt(pct * duration)
  }

  const $progress = art.template?.$progress as HTMLElement | undefined
  if ($progress) {
    const interceptSeek = (event: Event) => {
      if (!isVirtualVodTimelineActive()) return
      event.preventDefault()
      event.stopPropagation()
      seekVirtualVodFromEvent(event as MouseEvent | TouchEvent)
    }
    const blockNativeSeek = (event: Event) => {
      if (!isVirtualVodTimelineActive()) return
      event.preventDefault()
      event.stopPropagation()
    }
    const updateHover = (event: Event) => {
      if (!isVirtualVodTimelineActive()) return
      const duration = virtualVodDuration()
      const rect = $progress.getBoundingClientRect()
      const clientX =
        "touches" in event && (event as TouchEvent).touches.length > 0
          ? (event as TouchEvent).touches[0]!.clientX
          : (event as MouseEvent).clientX
      const pct = Math.min(1, Math.max(0, (clientX - rect.left) / Math.max(1, rect.width)))
      const tip = $progress.querySelector(".art-progress-tip") as HTMLElement | null
      if (tip) tip.textContent = formatPlaybackClock(pct * duration)
    }
    $progress.addEventListener("click", interceptSeek, true)
    $progress.addEventListener("mousedown", blockNativeSeek, true)
    $progress.addEventListener("touchstart", interceptSeek, true)
    $progress.addEventListener("mousemove", updateHover, true)
  }
  art.on("raf", updateVirtualVodUi)
  art.on("video:timeupdate", updateVirtualVodUi)
  art.on("video:loadedmetadata", updateVirtualVodUi)
  art.on("video:progress", updateVirtualVodUi)

  const { wireNativeTracksForArtplayer } = await import(
    "@/scripts/lib/embedded-native-tracks.js"
  )
  wireNativeTracksForArtplayer(art)

  function markContainerTracksPending(playUrl: string): void {
    if (isLive || (!useDevStreamProxy() && !useNativeStreamProxy())) return
    const probeUrl =
      (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
      playUrl
    if (isContainerUrl(probeUrl)) {
      art._xtPendingContainerTracks = true
    }
  }

  function attachContainerTracksLater(playUrl: string): void {
    if (isLive) return
    const probeUrl =
      (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
      playUrl
    void import("@/scripts/lib/stream-proxy.js")
      .then(({ vodAssetPathKey }) => {
        const key = vodAssetPathKey(probeUrl)
        if (art._xtContainerTracks && art._xtContainerProbeKey === key) {
          art._xtPendingContainerTracks = false
          return
        }
        markContainerTracksPending(playUrl)
        return import("@/scripts/lib/embedded-container-tracks.js")
      })
      .then((mod) => {
        if (!mod?.attachContainerTracksForArtplayer) return
        return mod.attachContainerTracksForArtplayer(art, probeUrl)
      })
      .catch((error) => {
        art._xtPendingContainerTracks = false
        if (import.meta.env.DEV) {
          log.debug("[xt:player] container tracks skipped", error)
        }
      })
  }

  function emitSourcePrepared(
    originalUrl: string,
    playUrl: string,
    resolvedUrl: string,
  ): void {
    try {
      document.dispatchEvent(
        new CustomEvent("xt:player-source-prepared", {
          detail: {
            originalUrl: redactUrl(originalUrl),
            playUrl: redactUrl(playUrl),
            resolvedUrl: redactUrl(resolvedUrl),
            changed: playUrl !== originalUrl,
          },
        }),
      )
    } catch {}
  }

  async function assignArtPlayback(
    originalSrc: string,
    playUrl: string,
    type: string | undefined,
    kind: StreamKind | "unknown",
    resolvedUrl: string,
    generation: number,
  ): Promise<void> {
    if (generation !== loadGeneration || pendingSrc !== originalSrc) return
    art._xtVodSourceUrl = playUrl
    emitSourcePrepared(originalSrc, playUrl, resolvedUrl)

    if (kind === "hls") {
      art._xtVirtualTimelineInstalled = false
      art.type = "m3u8"
      art.url = resolvedUrl
      if (!isLive) {
        const probeUrl =
          (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
          originalSrc
        if (isContainerUrl(probeUrl)) {
          markContainerTracksPending(probeUrl)
          attachContainerTracksLater(probeUrl)
        }
      }
      resumePlayAfterSourceChange()
      return
    }
    if (kind === "ts") {
      art._xtVirtualTimelineInstalled = resolvedUrl.includes("/__transcode")
      art.type = "ts"
      emitPlayerDebug("assign ts playback", { resolvedUrl, originalSrc, playUrl })
      art.url = resolvedUrl
      const probeUrl =
        (typeof art._xtTranscodeSrcUrl === "string" && art._xtTranscodeSrcUrl) ||
        ""
      if (probeUrl) {
        markContainerTracksPending(probeUrl)
        attachContainerTracksLater(probeUrl)
      }
      resumePlayAfterSourceChange()
      return
    }
    if (kind === "dash") {
      art._xtVirtualTimelineInstalled = false
      art.type = "mpd"
      art.url = resolvedUrl
      resumePlayAfterSourceChange()
      return
    }
    art.type = artplayerTypeForUrl(playUrl, kind === "unknown" ? "native" : kind)
    art._xtVirtualTimelineInstalled = false
    const isNativeContainer = kind === "native" || art.type === "xt-native"
    if (isNativeContainer && !isLive) {
      const { canPlayVodNativeOnTauri } = await import(
        "@/scripts/lib/embedded-vod-playback.js"
      )
      const upstream = unwrapStreamProxyUrl(playUrl)
      if (!(await canPlayVodNativeOnTauri(upstream))) {
        log.warn("[xt:player] ArtPlayer VOD native blocked", {
          src: redactUrl(upstream).slice(0, 120),
        })
        art.url = ""
        setArtplayerLoading(art, false)
        if (await retryEmbeddedVodWithMkv(upstream, art, (url) => { pendingSrc = url })) return
        if (!(await tryExternalVodPlaceholderFallback(upstream))) {
          toastError(
            "This title cannot play in the embedded player. Install ffmpeg (brew install ffmpeg) or use MPV/VLC in Settings → Playback.",
            { duration: 11000 },
          )
        }
        return
      }
    }
    if (isNativeContainer) {
      const { vodStreamPathsEquivalent } = await import(
        "@/scripts/lib/stream-proxy.js"
      )
      const currentSrc =
        (art.video as HTMLVideoElement | undefined)?.src ||
        (typeof art.url === "string" ? art.url : "")
      if (
        art._xtContainerTracks &&
        currentSrc &&
        vodStreamPathsEquivalent(currentSrc, resolvedUrl)
      ) {
        if (
          typeof art._xtContainerProbeUrl !== "string" ||
          !art._xtContainerProbeUrl
        ) {
          art._xtContainerProbeUrl =
            (typeof art._xtContainerSourceUrl === "string" &&
              art._xtContainerSourceUrl) ||
            playUrl
        }
        resumePlayAfterSourceChange()
        return
      }
      markContainerTracksPending(playUrl)
    }
    art.url = resolvedUrl
    if (isNativeContainer) {
      attachContainerTracksLater(playUrl)
    }
    resumePlayAfterSourceChange()
  }

  async function probeHlsUpgradeInBackground(
    originalSrc: string,
    containerUrl: string,
    containerExtension: string | undefined,
    generation: number,
  ): Promise<void> {
    const { preferVodHlsUrl, shouldSkipVodHlsProbe, isVodHlsDenied } = await import(
      "@/scripts/lib/embedded-vod-playback.js"
    )
    if (shouldSkipVodHlsProbe(containerUrl, containerExtension)) return
    if (isVodHlsDenied(originalSrc) || isVodHlsDenied(containerUrl)) return
    const hlsUrl = await preferVodHlsUrl(originalSrc, { containerExtension })
    if (generation !== loadGeneration || pendingSrc !== originalSrc) return
    if (hlsUrl === containerUrl || hlsUrl === originalSrc) return
    if (streamKindHint(hlsUrl, undefined) !== "hls") return
    const resolvedHls = await resolveHlsPlaybackUrl(hlsUrl)
    pendingVodFallbackUrl = await resolveArtNativePlayUrl(
      preferPlainHttpForXtreamMedia(originalSrc),
    )
    log.debug("[xt:player] VOD upgrading to HLS after quick container start", {
      hls: redactUrl(resolvedHls).slice(0, 120),
    })
    art._xtContainerTracks = false
    art._xtContainerProbeKey = undefined
    art._xtContainerAttachInflight = undefined
    art.type = "m3u8"
    art.url = resolvedHls
  }

  function resumePlayAfterSourceChange(): void {
    if (!art._xtPlayAfterSourceLoad) return
    art._xtPlayAfterSourceLoad = false
    const run = () => {
      const playPromise = art.play()
      if (playPromise && typeof playPromise.catch === "function") {
        playPromise.catch(() => {})
      }
    }
    if (art.video && art.video.readyState >= 2) {
      run()
      return
    }
    art.once("video:canplay", run)
  }

  async function loadArtSrc(
    src: string,
    type?: string,
    containerExtension?: string,
    remoteSourceUrl?: string,
    startSeconds = 0,
    expectedDurationSeconds = 0,
  ): Promise<void> {
    const generation = ++loadGeneration
    pendingSrc = src
    destroyActiveEmbeddedHandles()
    art.hls = null
    art._xtVodSourceUrl = src
    art._xtContainerProbeUrl = remoteSourceUrl || ""
    art._xtPlaybackOffsetSeconds = 0
    art._xtExpectedDurationSeconds =
      Number.isFinite(expectedDurationSeconds) && expectedDurationSeconds > 0
        ? expectedDurationSeconds
        : 0
    const { vodAssetPathKey } = await import("@/scripts/lib/stream-proxy.js")
    const incomingVodKey = vodAssetPathKey(remoteSourceUrl || src)
    const keepingSameVodAsset =
      typeof art._xtContainerProbeKey === "string" &&
      art._xtContainerProbeKey === incomingVodKey
    if (!keepingSameVodAsset) {
      art._xtContainerTracks = false
      art._xtContainerProbeKey = undefined
      art._xtContainerAttachInflight = undefined
    }
    wireArtLoadingUntilPlay(art)

    const {
      preferVodHlsUrl,
      containerExtensionFromUrl,
      shouldSkipVodHlsProbe,
      isXtreamVodContainerUrl,
    } = await import("@/scripts/lib/embedded-vod-playback.js")

    const ext = containerExtension || containerExtensionFromUrl(src)
    const normalized = preferPlainHttpForXtreamMedia(src)
    emitPlayerDebug("loadArtSrc", {
      src,
      type,
      ext,
      normalized,
      isLive,
      isTauri: isTauriEmbedded(),
      isXtreamVod: isXtreamVodContainerUrl(normalized),
      expectedDurationSeconds,
      startSeconds,
    })

    if (!isLive && isXtreamVodContainerUrl(normalized)) {
      if (!isTauriEmbedded()) {
        emitPlayerDebug("loadArtSrc web/native branch", { normalized })
        markContainerTracksPending(normalized)
        const quickUrl = await resolveArtNativePlayUrl(normalized)
        if (generation !== loadGeneration || pendingSrc !== src) return
        pendingVodFallbackUrl = quickUrl
        await assignArtPlayback(src, normalized, type, "native", quickUrl, generation)
        if (!shouldSkipVodHlsProbe(normalized, ext)) {
          void probeHlsUpgradeInBackground(src, normalized, ext, generation)
        }
        return
      }
      const hlsPlayUrl = await preferVodHlsUrl(normalized, { containerExtension: ext })
      if (generation !== loadGeneration || pendingSrc !== src) return
      if (/\/__vod_hls(?:\/|[?#]|$)/i.test(hlsPlayUrl) || /\.m3u8(?:[?#]|$)/i.test(hlsPlayUrl)) {
        emitPlayerDebug("loadArtSrc tauri hls branch", { hlsPlayUrl })
        art._xtTranscodeSrcUrl = ""
        art._xtPlaybackOffsetSeconds = 0
        const probeUrl =
          (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
          normalized
        markContainerTracksPending(probeUrl)
        attachContainerTracksLater(probeUrl)
        pendingVodFallbackUrl = await resolveArtNativePlayUrl(normalized)
        await assignArtPlayback(
          src,
          hlsPlayUrl,
          type,
          "hls",
          await resolveHlsPlaybackUrl(hlsPlayUrl),
          generation,
        )
        return
      }
      const referer = (() => {
        try {
          return `${new URL(normalized).origin}/`
        } catch {
          return ""
        }
      })()
      const transcodeUrl = await resolveTranscodeProxyUrl(
        normalized,
        referer,
        0,
        startSeconds,
      )
      emitPlayerDebug("transcode resolved", {
        ok: Boolean(transcodeUrl),
        transcodeUrl,
        referer,
        startSeconds,
      })
      if (transcodeUrl) {
        art._xtTranscodeSrcUrl = normalized
        const probeUrl =
          (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
          normalized
        markContainerTracksPending(probeUrl)
        attachContainerTracksLater(probeUrl)
        await assignArtPlayback(
          src,
          transcodeUrl,
          type,
          "ts",
          transcodeUrl,
          generation,
        )
        return
      }
      const playUrl = await preferVodHlsUrl(src, { containerExtension: ext })
      if (generation !== loadGeneration || pendingSrc !== src) return
      const hint = streamKindHint(playUrl, type)
      pendingVodFallbackUrl =
        hint === "hls"
          ? await resolveArtNativePlayUrl(
              /\.mp4(?:[?#]|$)/i.test(playUrl)
                ? playUrl
                : preferPlainHttpForXtreamMedia(normalized),
            )
          : null
      const resolvedUrl =
        hint === "native"
          ? await resolveArtNativePlayUrl(playUrl)
          : hint === "hls"
            ? await resolveHlsPlaybackUrl(playUrl)
            : resolveEmbeddedStreamUrl(playUrl)
      await assignArtPlayback(src, playUrl, type, hint, resolvedUrl, generation)
      return
    }

    let playUrl = src
    if (!isLive) {
      playUrl = await preferVodHlsUrl(src, { containerExtension: ext })
    }
    if (generation !== loadGeneration || pendingSrc !== src) return

    const hint = streamKindHint(playUrl, type)
    pendingVodFallbackUrl =
      !isLive && hint === "hls"
        ? await resolveArtNativePlayUrl(
            /\.mp4(?:[?#]|$)/i.test(playUrl)
              ? playUrl
              : preferPlainHttpForXtreamMedia(src),
          )
        : null

    const resolvedUrl =
      hint === "native"
        ? await resolveArtNativePlayUrl(playUrl)
        : hint === "hls"
          ? await resolveHlsPlaybackUrl(playUrl)
          : resolveEmbeddedStreamUrl(playUrl)

    if (hint === "hls" || hint === "ts" || hint === "dash" || hint === "native") {
      await assignArtPlayback(src, playUrl, type, hint, resolvedUrl, generation)
      return
    }

    art.url = ""
    try {
      const kind = await probeContainer(playUrl)
      if (generation !== loadGeneration || pendingSrc !== src) return
      await assignArtPlayback(src, playUrl, type, kind, resolvedUrl, generation)
    } catch {
      if (generation !== loadGeneration || pendingSrc !== src) return
      art.type = "m3u8"
      art.url = resolvedUrl
    }
  }

  const handle: VjsLikeHandle = {
    src({ src, type, containerExtension, remoteSourceUrl, startSeconds, expectedDurationSeconds }) {
      pendingLoad = loadArtSrc(
        src,
        type,
        containerExtension,
        remoteSourceUrl,
        startSeconds,
        expectedDurationSeconds,
      )
        .catch((error) => {
          log.warn("[xt:player] ArtPlayer source preparation failed", error)
          setArtplayerLoading(art, false)
        })
        .finally(() => {
          pendingLoad = null
        })
    },
    async play() {
      const runPlay = async () => {
        const first = art.play()
        if (first instanceof Promise) {
          return first.catch(async () => {
            await new Promise<void>((r) => setTimeout(r, 400))
            if (!art.video || !art.video.paused) return
            return art.play()?.catch(() => {})
          })
        }
        return first
      }
      if (pendingLoad) {
        art._xtPlayAfterSourceLoad = true
        await pendingLoad
      }
      return runPlay()
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
      loadGeneration += 1
      pendingSrc = null
      pendingLoad = null
      destroyActiveEmbeddedHandles()
      art.hls = null
      art.url = ""
    },
    dispose() {
      pendingSrc = null
      destroyActiveEmbeddedHandles()
      try { art.destroy(false) } catch {}
    },
    duration() {
      if (
        Number.isFinite(art._xtExpectedDurationSeconds) &&
        Number(art._xtExpectedDurationSeconds) > 0
      ) {
        return Number(art._xtExpectedDurationSeconds)
      }
      const dur = art.duration
      return Number.isFinite(dur) ? dur : 0
    },
    currentTime(value) {
      const offset =
        Number.isFinite(art._xtPlaybackOffsetSeconds)
          ? Number(art._xtPlaybackOffsetSeconds)
          : 0
      if (value === undefined) return offset + (art.currentTime || 0)
      if (
        art._xtVirtualTimelineInstalled &&
        Number.isFinite(art._xtExpectedDurationSeconds) &&
        Number(art._xtExpectedDurationSeconds) > 0 &&
        typeof art._xtRestartTranscodeAt === "function"
      ) {
        void art._xtRestartTranscodeAt(value)
        return value
      }
      art.currentTime = Math.max(0, value - offset)
      return value
    },
    on(event, fn) {
      if (event === "error") {
        const listener = (ev: Event) => {
          if (shouldIgnoreContainerVideoError(art)) {
            log.debug("[xt:player] ignored video error during track swap")
            return
          }
          fn(ev)
        }
        art.video?.addEventListener(event, listener)
        return
      }
      art.video?.addEventListener(event, fn as EventListener)
    },
    off(event, fn) {
      art.video?.removeEventListener(event, fn as EventListener)
    },
    one(event, fn) {
      if (event === "error") {
        const listener = (ev: Event) => {
          if (shouldIgnoreContainerVideoError(art)) {
            log.debug("[xt:player] ignored video error during track swap")
            return
          }
          art.video?.removeEventListener(event, listener)
          fn(ev)
        }
        art.video?.addEventListener(event, listener)
        return
      }
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
  backend: PlayerBackend = getPlayerBackend() as PlayerBackend,
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
    const handle = await mountArtPlayer(videoEl, options)
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
