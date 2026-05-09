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
  | { kind: "embedded"; backend: "videojs" | "artplayer"; handle: VjsLikeHandle }
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
  const resume = Number(input.resumeSeconds || 0)
  if (Number.isFinite(resume) && resume > minResume) {
    out.push(`--start=${Math.floor(resume)}`)
  }
  for (const arg of input.extraArgs || []) {
    if (arg) out.push(arg)
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
    if (arg) out.push(arg)
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
  })
  return player as unknown as VjsLikeHandle
}

async function mountArtPlayer(videoEl: HTMLVideoElement): Promise<VjsLikeHandle> {
  const [{ default: Artplayer }, { default: Hls }] = await Promise.all([
    import("artplayer"),
    import("hls.js"),
  ])

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
      m3u8(video, url) {
        if (activeHls) {
          try { activeHls.destroy() } catch {}
          activeHls = null
        }
        if ((Hls as any).isSupported()) {
          const hls = new (Hls as any)({ enableWorker: true })
          hls.loadSource(url)
          hls.attachMedia(video)
          activeHls = hls
        } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
          video.src = url
        } else {
          log.warn("[xt:player] hls.js unsupported and no native HLS; fallback to <video src>")
          video.src = url
        }
      },
    },
  })

  art.on("destroy", () => {
    if (activeHls) {
      try { activeHls.destroy() } catch {}
      activeHls = null
    }
  })

  const handle: VjsLikeHandle = {
    src({ src, type }) {
      if (activeHls) {
        try { activeHls.destroy() } catch {}
        activeHls = null
      }
      const isM3u8 = type === "application/x-mpegURL" || /\.m3u8(\?|$)/i.test(src)
      art.type = isM3u8 ? "m3u8" : ""
      art.url = src
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
      if (activeHls) {
        try { activeHls.destroy() } catch {}
        activeHls = null
      }
      art.url = ""
    },
    dispose() {
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
  if (backend === "mpv" || backend === "vlc") {
    if (!externalPlayersAvailable) {
      // Fall back to the default in-app backend if external isn't possible.
      log.warn(`[xt:player] external backend "${backend}" requested but not available; falling back to videojs`)
      return mountPlayer(videoEl, "videojs", options)
    }
    return {
      kind: "external",
      backend,
      launcher: getExternalLauncher(backend),
    }
  }
  if (backend === "artplayer") {
    const handle = await mountArtPlayer(videoEl)
    return {
      kind: "embedded",
      backend: "artplayer",
      handle,
    }
  }
  // videojs (default)
  const handle = await mountVideoJs(videoEl, options)
  return {
    kind: "embedded",
    backend: "videojs",
    handle,
  }
}

export function isExternalBackend(backend: PlayerBackend): boolean {
  return EXTERNAL_PLAYER_BACKENDS.includes(backend as ExternalPlayerKind)
}
