import { log, redactUrl } from "@/scripts/lib/log.js"
import {
  mountPlayer,
  type Mounted,
  type MountOptions,
  type PlayerBackend,
  type VjsLikeHandle,
  type VjsSrcOptions,
} from "@/scripts/lib/player-runtime.ts"
import {
  isIosEmbedded,
  isTauriEmbedded,
  useNativeStreamProxy,
} from "@/scripts/lib/stream-proxy"

// Disabled by design while native apps are being rebuilt around a dedicated
// player architecture. The current Tauri/libmpv experiment can play audio, but
// video layering and control dispatch are unreliable in macOS WebView.
const ENABLE_TAURI_NATIVE_PLAYBACK = false

export type PlaybackSessionKind = "web" | "native"
export type PlaybackRuntimeBackend = "videojs" | "artplayer" | "native"
export type NativePlaybackBackend =
  | "macos-libmpv"
  | "linux-libmpv"
  | "windows-libmpv"
  | "android-exoplayer"
  | "ios-avplayer"
  | "tizen-avplay"
  | "unsupported"

export interface PlaybackSource extends VjsSrcOptions {
  userAgent?: string | null
  referer?: string | null
}

export interface PlaybackSessionOptions extends MountOptions {
  nativeStatus?: NativePlaybackStatus | null
}

export type PlaybackTrackKind = "audio" | "subtitle"

export interface PlaybackTrack {
  id: string
  kind: PlaybackTrackKind
  label: string
  language: string
  index: number
  active: boolean
}

export interface PlaybackTracksState {
  audio: PlaybackTrack[]
  subtitles: PlaybackTrack[]
  selectedAudioId: string | null
  selectedSubtitleId: string | null
}

export interface PlaybackState {
  backend: PlaybackRuntimeBackend
  currentTime: number
  duration: number
  paused: boolean | null
  ended: boolean | null
  error: unknown
  tracks: PlaybackTracksState
}

export interface PlaybackCapabilities {
  kind: PlaybackSessionKind
  backend: PlaybackRuntimeBackend
  tauri: boolean
  ios: boolean
  android: boolean
  nativeStreamProxy: boolean
  webViewPrimaryPlayback: boolean
  nativeIntegratedPlayback: boolean
  externalFallbackOnly: boolean
  selectedBackend: PlaybackRuntimeBackend | NativePlaybackBackend
  availableNativeBackends: NativePlaybackBackend[]
  recommendedNativeBackend: NativePlaybackBackend | null
}

export interface PlaybackSession {
  readonly kind: PlaybackSessionKind
  readonly backend: PlaybackRuntimeBackend
  readonly capabilities: PlaybackCapabilities
  readonly handle: VjsLikeHandle
  load(source: PlaybackSource): void
  play(): Promise<unknown> | void
  pause(): void
  stop(): void
  seek(seconds: number): void
  setVolume(volume: number): void
  getTracks(): PlaybackTracksState
  selectAudioTrack(id: string): void
  selectSubtitleTrack(id: string | null): void
  setSubtitleDelay(seconds: number): void
  getState(): PlaybackState
  on(event: string, listener: (payload: unknown) => void): () => void
  dispose(): void
}

export interface NativePlaybackStatus {
  platform: string
  available: boolean
  backend: NativePlaybackBackend
  integrated: boolean
  reason: string
  nextStep: string
}

interface NativePlaybackSnapshot {
  backend: NativePlaybackBackend
  available: boolean
  loaded: boolean
  paused: boolean
  ended: boolean
  currentTime: number
  duration: number
  audio: PlaybackTrack[]
  subtitles: PlaybackTrack[]
  selectedAudioId: string | null
  selectedSubtitleId: string | null
  error: string | null
}

interface NativePlaybackRect {
  x: number
  y: number
  width: number
  height: number
  scaleFactor: number
}

function isAndroidRuntime(): boolean {
  if (typeof navigator === "undefined") return false
  return /Android/i.test(navigator.userAgent || "")
}

function nativePlaybackCapabilities(
  nativeStatus: NativePlaybackStatus,
): PlaybackCapabilities {
  const tauri = isTauriEmbedded()
  const ios = isIosEmbedded()
  const android = isAndroidRuntime()
  return {
    kind: "native",
    backend: "native",
    tauri,
    ios,
    android,
    nativeStreamProxy: useNativeStreamProxy(),
    webViewPrimaryPlayback: false,
    nativeIntegratedPlayback: nativeStatus.integrated === true,
    externalFallbackOnly: false,
    selectedBackend: nativeStatus.backend,
    availableNativeBackends:
      nativeStatus.available && nativeStatus.backend !== "unsupported"
        ? [nativeStatus.backend]
        : [],
    recommendedNativeBackend: nativeStatus.backend,
  }
}

function playbackCapabilities(
  backend: PlaybackRuntimeBackend,
  nativeStatus: NativePlaybackStatus | null = null,
): PlaybackCapabilities {
  const tauri = isTauriEmbedded()
  const ios = isIosEmbedded()
  const android = isAndroidRuntime()
  const recommendedNativeBackend = nativeStatus?.backend || null
  const availableNativeBackends =
    nativeStatus?.available && nativeStatus.backend !== "unsupported"
      ? [nativeStatus.backend]
      : []
  return {
    kind: "web",
    backend,
    tauri,
    ios,
    android,
    nativeStreamProxy: useNativeStreamProxy(),
    webViewPrimaryPlayback: tauri,
    nativeIntegratedPlayback: nativeStatus?.integrated === true,
    externalFallbackOnly: false,
    selectedBackend: backend,
    availableNativeBackends,
    recommendedNativeBackend,
  }
}

function emitCapabilityLog(capabilities: PlaybackCapabilities) {
  log.info("[xt:playback] session mounted", capabilities)
  try {
    document.dispatchEvent(
      new CustomEvent("xt:playback-session-mounted", {
        detail: capabilities,
      }),
    )
  } catch {
    // Some document contexts used in tests do not allow dispatching custom events.
  }
}

function findMediaElement(root: HTMLElement | null | undefined): HTMLVideoElement | null {
  if (!root) return null
  if (typeof HTMLVideoElement !== "undefined" && root instanceof HTMLVideoElement) {
    return root
  }
  return root.querySelector?.("video") as HTMLVideoElement | null
}

function trackId(track: unknown, index: number): string {
  const candidate = track as { id?: unknown }
  const id = String(candidate?.id || "").trim()
  return id || String(index)
}

function trackLabel(track: unknown, fallback: string): string {
  const candidate = track as { label?: unknown; language?: unknown }
  const label = String(candidate?.label || "").trim()
  if (label) return label
  const language = String(candidate?.language || "").trim()
  return language || fallback
}

function audioTrackActive(track: unknown): boolean {
  return Boolean((track as { enabled?: unknown })?.enabled)
}

function subtitleTrackActive(track: unknown): boolean {
  return (track as { mode?: unknown })?.mode === "showing"
}

export function snapshotMediaTracksFromElement(
  video: HTMLVideoElement | null | undefined,
): PlaybackTracksState {
  const audioSource = (video as unknown as { audioTracks?: ArrayLike<unknown> })
    ?.audioTracks
  const textSource = video?.textTracks
  const audio = Array.from(audioSource || []).map((track, index) => ({
    id: trackId(track, index),
    kind: "audio" as const,
    label: trackLabel(track, `Audio ${index + 1}`),
    language: String((track as { language?: unknown })?.language || ""),
    index,
    active: audioTrackActive(track),
  }))
  const subtitles = Array.from(textSource || [])
    .filter((track) => {
      const kind = String((track as { kind?: unknown })?.kind || "")
      return kind !== "metadata"
    })
    .map((track, index) => ({
      id: trackId(track, index),
      kind: "subtitle" as const,
      label: trackLabel(track, `Subtitle ${index + 1}`),
      language: String((track as { language?: unknown })?.language || ""),
      index,
      active: subtitleTrackActive(track),
    }))
  return {
    audio,
    subtitles,
    selectedAudioId: audio.find((track) => track.active)?.id || null,
    selectedSubtitleId: subtitles.find((track) => track.active)?.id || null,
  }
}

export class WebPlaybackSession implements PlaybackSession {
  readonly kind = "web"
  readonly backend: PlaybackRuntimeBackend
  readonly capabilities: PlaybackCapabilities
  readonly handle: VjsLikeHandle
  readonly mounted: Extract<Mounted, { kind: "embedded" }>
  private readonly listeners = new Map<string, Set<(payload: unknown) => void>>()
  private readonly boundHandleEvents: Array<{
    event: string
    listener: (...args: unknown[]) => void
  }> = []

  constructor(
    mounted: Extract<Mounted, { kind: "embedded" }>,
    nativeStatus: NativePlaybackStatus | null = null,
  ) {
    this.mounted = mounted
    this.backend = mounted.backend
    this.handle = mounted.handle
    this.capabilities = playbackCapabilities(mounted.backend, nativeStatus)
    emitCapabilityLog(this.capabilities)
    this.bindStandardEvents()
  }

  load(source: PlaybackSource): void {
    log.info("[xt:playback] load", {
      backend: this.backend,
      src: redactUrl(source.src),
      type: source.type,
      containerExtension: source.containerExtension,
      expectedDurationSeconds: source.expectedDurationSeconds,
    })
    this.handle.src(source)
  }

  play(): Promise<unknown> | void {
    return this.handle.play?.()
  }

  pause(): void {
    this.handle.pause?.()
  }

  stop(): void {
    try {
      this.handle.pause?.()
    } catch {
      // Best-effort stop: some backend handles may already be disposed.
    }
    try {
      this.handle.reset?.()
    } catch {
      // Best-effort stop: reset is optional and backend-specific.
    }
  }

  seek(seconds: number): void {
    this.handle.currentTime?.(seconds)
  }

  setVolume(volume: number): void {
    const normalized = Math.max(0, Math.min(100, Number(volume) || 0))
    const video = this.getMediaElement()
    if (video) video.volume = normalized / 100
  }

  getTracks(): PlaybackTracksState {
    return snapshotMediaTracksFromElement(this.getMediaElement())
  }

  selectAudioTrack(id: string): void {
    const video = this.getMediaElement()
    const tracks = (video as unknown as { audioTracks?: ArrayLike<unknown> })
      ?.audioTracks
    if (!tracks) return
    Array.from(tracks).forEach((track, index) => {
      ;(track as { enabled?: boolean }).enabled = trackId(track, index) === id
    })
    this.emit("tracks", this.getTracks())
  }

  selectSubtitleTrack(id: string | null): void {
    const tracks = this.getMediaElement()?.textTracks
    if (!tracks) return
    Array.from(tracks).forEach((track, index) => {
      const isMetadata = track.kind === "metadata"
      const selected = id != null && trackId(track, index) === id
      track.mode = !isMetadata && selected ? "showing" : "disabled"
    })
    this.emit("tracks", this.getTracks())
  }

  setSubtitleDelay(seconds: number): void {
    log.info("[xt:playback] subtitle delay not supported by web session", {
      seconds,
      backend: this.backend,
    })
  }

  getState(): PlaybackState {
    const paused = this.handle.paused?.()
    const video = this.getMediaElement()
    return {
      backend: this.backend,
      currentTime: this.handle.currentTime?.() || 0,
      duration: this.handle.duration?.() || 0,
      paused: typeof paused === "boolean" ? paused : null,
      ended: video ? video.ended : null,
      error: this.handle.error?.() || video?.error || null,
      tracks: this.getTracks(),
    }
  }

  on(event: string, listener: (payload: unknown) => void): () => void {
    const listeners = this.listeners.get(event) || new Set()
    listeners.add(listener)
    this.listeners.set(event, listeners)
    return () => {
      listeners.delete(listener)
      if (listeners.size === 0) this.listeners.delete(event)
    }
  }

  dispose(): void {
    for (const { event, listener } of this.boundHandleEvents) {
      this.handle.off?.(event, listener)
    }
    this.boundHandleEvents.length = 0
    this.listeners.clear()
    this.handle.dispose?.()
  }

  private getMediaElement(): HTMLVideoElement | null {
    return findMediaElement(this.handle.el?.())
  }

  private bindStandardEvents(): void {
    const events = [
      "loadstart",
      "loadedmetadata",
      "canplay",
      "playing",
      "pause",
      "timeupdate",
      "durationchange",
      "waiting",
      "stalled",
      "ended",
      "error",
    ]
    for (const event of events) {
      const listener = (...args: unknown[]) => this.emit(event, {
        state: this.getState(),
        args,
      })
      this.handle.on(event, listener)
      this.boundHandleEvents.push({ event, listener })
    }
    const video = this.getMediaElement()
    try {
      ;(
        video as unknown as { audioTracks?: EventTarget }
      )?.audioTracks?.addEventListener?.("change", () => {
        this.emit("tracks", this.getTracks())
      })
    } catch {
      // Non-standard media track lists vary by browser.
    }
    try {
      video?.textTracks?.addEventListener?.("change", () => {
        this.emit("tracks", this.getTracks())
      })
    } catch {
      // TextTrackList event support is browser-specific.
    }
  }

  private emit(event: string, payload: unknown): void {
    this.listeners.get(event)?.forEach((listener) => {
      try {
        listener(payload)
      } catch (error) {
        log.warn("[xt:playback] listener failed", error)
      }
    })
    try {
      document.dispatchEvent(
        new CustomEvent(`xt:playback:${event}`, {
          detail: {
            backend: this.backend,
            kind: this.kind,
            payload,
          },
        }),
      )
    } catch {
      // Tests and non-document contexts may not allow DOM events.
    }
  }
}

type TauriInvoke = <T = unknown>(cmd: string, args?: Record<string, unknown>) => Promise<T>

async function getTauriInvoke(): Promise<TauriInvoke | null> {
  if (!isTauriEmbedded()) return null
  try {
    const core = await import("@tauri-apps/api/core")
    return core.invoke as TauriInvoke
  } catch (error) {
    log.warn("[xt:playback] Tauri invoke import failed", error)
    return null
  }
}

export async function getNativePlaybackStatus(): Promise<NativePlaybackStatus | null> {
  const invoke = await getTauriInvoke()
  if (!invoke) return null
  try {
    const status = await invoke<NativePlaybackStatus>("native_playback_status")
    log.info("[xt:playback] native status", status)
    return status
  } catch (error) {
    log.warn("[xt:playback] native status unavailable", error)
    return null
  }
}

export function isNativeIntegratedPlaybackAvailable(
  status: NativePlaybackStatus | null | undefined,
): boolean {
  return Boolean(ENABLE_TAURI_NATIVE_PLAYBACK && status?.available && status.integrated)
}

export class NativePlaybackSession implements PlaybackSession {
  readonly kind = "native"
  readonly backend = "native"
  readonly capabilities: PlaybackCapabilities
  readonly handle: VjsLikeHandle
  private readonly listeners = new Map<string, Set<(payload: unknown) => void>>()
  private readonly handleListeners = new Map<
    string,
    Map<(...args: unknown[]) => void, (payload: unknown) => void>
  >()
  private pollTimer: number | null = null
  private lastState: PlaybackState | null = null
  private fallbackEl: HTMLElement | null = null
  private trackBarEl: HTMLElement | null = null
  private resizeObserver: ResizeObserver | null = null
  private connectionWatchTimer: number | null = null
  private pendingLoad: Promise<void> | null = null
  private lastTrackSignature = ""
  private lastGoodRect: NativePlaybackRect | null = null
  private playbackRate = 1
  private miniMode = false
  private readonly initialHref =
    typeof window !== "undefined" && window.location ? window.location.href : ""

  constructor(
    private readonly videoEl: HTMLVideoElement,
    private readonly invoke: TauriInvoke,
    private readonly nativeStatus: NativePlaybackStatus,
  ) {
    this.capabilities = nativePlaybackCapabilities(nativeStatus)
    this.handle = this.createHandle()
    emitCapabilityLog(this.capabilities)
    this.setDocumentNativePlaybackActive(true)
    this.startSurfaceTracking()
    this.startNavigationCleanup()
  }

  load(source: PlaybackSource): void {
    const payload = {
      source: {
        src: source.src,
        mime: source.type,
        startSeconds: source.startSeconds || 0,
        expectedDurationSeconds: source.expectedDurationSeconds || 0,
        userAgent: source.userAgent || null,
        referer: source.referer || null,
      },
    }
    this.pendingLoad = (async () => {
      await this.attachSurface()
      log.info("[xt:playback] native load start", {
        src: redactUrl(source.src),
        mime: source.type,
        startSeconds: payload.source.startSeconds,
        expectedDurationSeconds: payload.source.expectedDurationSeconds,
      })
      await this.invoke("native_playback_load", payload)
      log.info("[xt:playback] native load ok", {
        src: redactUrl(source.src),
      })
      this.emit("loadstart", this.getState())
      this.startPolling()
    })().catch((error) => {
      log.warn("[xt:playback] native load failed", error)
      this.emitError(error)
      throw error
    })
  }

  play(): Promise<unknown> {
    return Promise.resolve(this.pendingLoad)
      .then(() => this.invoke("native_playback_play"))
      .then(() => {
        log.info("[xt:playback] native play ok")
        return this.refreshState("playing")
      })
      .catch((error) => {
        log.warn("[xt:playback] native play failed", error)
        this.emitError(error)
        throw error
      })
  }

  pause(): void {
    void this.invoke("native_playback_pause")
      .then(() => this.refreshState("pause"))
      .catch((error) => this.emitError(error))
  }

  stop(): void {
    void this.invoke("native_playback_stop")
      .then(() => this.refreshState("ended"))
      .catch((error) => this.emitError(error))
  }

  seek(seconds: number): void {
    void this.invoke("native_playback_seek", { seconds })
      .then(() => this.refreshState("timeupdate"))
      .catch((error) => this.emitError(error))
  }

  setVolume(volume: number): void {
    const normalized = Math.max(0, Math.min(100, Number(volume) || 0))
    void this.invoke("native_playback_set_volume", { volume: normalized })
      .then(() => this.refreshState("volumechange"))
      .catch((error) => this.emitError(error))
  }

  getTracks(): PlaybackTracksState {
    return this.lastState?.tracks || emptyTracks()
  }

  selectAudioTrack(id: string): void {
    log.info("[xt:playback] native select audio", { id })
    void this.invoke("native_playback_select_audio_track", { id })
      .then(() => this.refreshState("tracks"))
      .catch((error) => this.emitError(error))
  }

  selectSubtitleTrack(id: string | null): void {
    log.info("[xt:playback] native select subtitle", { id })
    void this.invoke("native_playback_select_subtitle_track", { id })
      .then(() => this.refreshState("tracks"))
      .catch((error) => this.emitError(error))
  }

  setSubtitleDelay(seconds: number): void {
    void this.invoke("native_playback_set_subtitle_delay", { seconds })
      .then(() => this.refreshState("tracks"))
      .catch((error) => this.emitError(error))
  }

  private setPlaybackRate(rate: number): void {
    const speed = Math.max(0.25, Math.min(4, Number(rate) || 1))
    this.playbackRate = speed
    log.info("[xt:playback] native set speed", { speed })
    void this.invoke("native_playback_set_speed", { speed })
      .then(() => this.refreshState("ratechange"))
      .catch((error) => this.emitError(error))
  }

  getState(): PlaybackState {
    if (this.lastState) return this.lastState
    return {
      backend: "native",
      currentTime: 0,
      duration: 0,
      paused: null,
      ended: null,
      error: null,
      tracks: emptyTracks(),
    }
  }

  on(event: string, listener: (payload: unknown) => void): () => void {
    const listeners = this.listeners.get(event) || new Set()
    listeners.add(listener)
    this.listeners.set(event, listeners)
    return () => {
      listeners.delete(listener)
      if (listeners.size === 0) this.listeners.delete(event)
    }
  }

  dispose(): void {
    this.stopPolling()
    this.stopSurfaceTracking()
    this.stopNavigationCleanup()
    this.removeTrackBar()
    this.setDocumentNativePlaybackActive(false)
    this.listeners.clear()
    this.handleListeners.clear()
    void this.invoke("native_playback_stop").catch(() => {})
  }

  private setDocumentNativePlaybackActive(active: boolean): void {
    if (typeof document === "undefined") return
    const root = document.documentElement
    const body = document.body
    if (active) {
      root.dataset.nativePlaybackActive = "true"
      body?.setAttribute("data-native-playback-active", "true")
    } else {
      delete root.dataset.nativePlaybackActive
      body?.removeAttribute("data-native-playback-active")
    }
  }

  private createHandle(): VjsLikeHandle {
    return {
      src: (source) => this.load(source),
      play: () => this.play(),
      pause: () => this.pause(),
      paused: () => this.getState().paused === true,
      muted: () => false,
      reset: () => this.stop(),
      dispose: () => this.dispose(),
      duration: () => this.getState().duration,
      currentTime: (value?: number) => {
        if (typeof value === "number") {
          this.seek(value)
        }
        return this.getState().currentTime
      },
      on: (event, fn) => {
        const wrapped = (payload: unknown) => fn(payload)
        const eventListeners = this.handleListeners.get(event) || new Map()
        eventListeners.set(fn, wrapped)
        this.handleListeners.set(event, eventListeners)
        this.on(event, wrapped)
      },
      off: (event, fn) => {
        const eventListeners = this.handleListeners.get(event)
        const wrapped = eventListeners?.get(fn)
        if (!wrapped) return
        eventListeners?.delete(fn)
        this.listeners.get(event)?.delete(wrapped)
      },
      one: (event, fn) => {
        const off = this.on(event, (payload) => {
          off()
          fn(payload)
        })
      },
      el: () => this.nativeElement(),
      error: () => this.getState().error,
      requestFullscreen: () => this.nativeElement().requestFullscreen?.(),
      userActive: () => {},
    }
  }

  private nativeElement(): HTMLElement {
    return this.videoEl || this.fallbackElement()
  }

  private fallbackElement(): HTMLElement {
    if (!this.fallbackEl) {
      this.fallbackEl = document.createElement("div")
      this.fallbackEl.dataset.xtNativePlayback = "true"
    }
    return this.fallbackEl
  }

  private surfaceRect(): NativePlaybackRect {
    const rect = this.videoEl.getBoundingClientRect()
    const controlsInset = this.nativeStatus.backend === "macos-libmpv" ? 88 : 0
    const next = {
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: Math.max(1, rect.height - controlsInset),
      scaleFactor: typeof window !== "undefined" ? window.devicePixelRatio || 1 : 1,
    }
    const minHeight = this.miniMode ? 70 : 120
    if (next.width >= 160 && next.height >= minHeight) {
      this.lastGoodRect = next
      return next
    }
    if (this.lastGoodRect) {
      log.warn("[xt:playback] ignoring invalid native surface rect", {
        next,
        lastGood: this.lastGoodRect,
      })
      return this.lastGoodRect
    }
    return next
  }

  private async attachSurface(): Promise<void> {
    if (this.hasDetachedFromDocument()) {
      this.onPageExit()
      return
    }
    try {
      const result = await this.invoke("native_playback_attach", {
        rect: this.surfaceRect(),
      })
      log.info("[xt:playback] native surface attach", result)
    } catch (error) {
      log.warn("[xt:playback] native surface attach failed", error)
    }
  }

  private startSurfaceTracking(): void {
    if (typeof ResizeObserver !== "undefined") {
      this.resizeObserver = new ResizeObserver(() => {
        void this.attachSurface()
      })
      this.resizeObserver.observe(this.videoEl)
    }
    if (typeof window === "undefined") {
      void this.attachSurface()
      return
    }
    window.addEventListener("resize", this.onWindowResize)
    void this.attachSurface()
    this.connectionWatchTimer = window.setInterval(() => {
      if (this.hasDetachedFromDocument() || this.hasNavigatedAway()) this.onPageExit()
    }, 500)
  }

  private stopSurfaceTracking(): void {
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
    if (this.connectionWatchTimer != null && typeof window !== "undefined") {
      window.clearInterval(this.connectionWatchTimer)
      this.connectionWatchTimer = null
    }
    if (typeof window === "undefined") return
    window.removeEventListener("resize", this.onWindowResize)
  }

  private readonly onWindowResize = (): void => {
    void this.attachSurface()
  }

  private startNavigationCleanup(): void {
    if (typeof window !== "undefined") {
      window.addEventListener("pagehide", this.onPageExit)
      window.addEventListener("beforeunload", this.onPageExit)
      window.addEventListener("popstate", this.onPageExit)
      window.addEventListener("hashchange", this.onPageExit)
    }
    if (typeof document !== "undefined") {
      document.addEventListener("astro:before-swap", this.onPageExit)
      document.addEventListener("astro:before-preparation", this.onPageExit)
      document.addEventListener("click", this.onDocumentClick, true)
    }
  }

  private stopNavigationCleanup(): void {
    if (typeof window !== "undefined") {
      window.removeEventListener("pagehide", this.onPageExit)
      window.removeEventListener("beforeunload", this.onPageExit)
      window.removeEventListener("popstate", this.onPageExit)
      window.removeEventListener("hashchange", this.onPageExit)
    }
    if (typeof document !== "undefined") {
      document.removeEventListener("astro:before-swap", this.onPageExit)
      document.removeEventListener("astro:before-preparation", this.onPageExit)
      document.removeEventListener("click", this.onDocumentClick, true)
    }
  }

  private readonly onDocumentClick = (event: Event): void => {
    const target = event.target as Element | null
    const anchor = target?.closest?.("a[href]") as HTMLAnchorElement | null
    if (!anchor) return
    const href = anchor.getAttribute("href") || ""
    if (!href || href.startsWith("#")) return
    this.onPageExit()
  }

  private readonly onPageExit = (): void => {
    log.info("[xt:playback] native page exit cleanup", {
      initialHref: this.initialHref,
      currentHref: typeof window !== "undefined" && window.location ? window.location.href : "",
      detached: this.hasDetachedFromDocument(),
    })
    this.stopPolling()
    this.stopSurfaceTracking()
    this.removeTrackBar()
    this.setDocumentNativePlaybackActive(false)
    void this.invoke("native_playback_stop").catch((error) => {
      log.warn("[xt:playback] native stop on navigation failed", error)
    })
  }

  private hasDetachedFromDocument(): boolean {
    if (typeof Node === "undefined" || !(this.videoEl instanceof Node)) return false
    return !this.videoEl.isConnected
  }

  private hasNavigatedAway(): boolean {
    return Boolean(
      this.initialHref &&
        typeof window !== "undefined" &&
        window.location &&
        window.location.href !== this.initialHref,
    )
  }

  private async refreshState(event = "timeupdate"): Promise<void> {
    try {
      const snapshot = await this.invoke<NativePlaybackSnapshot>("native_playback_state")
      this.lastState = stateFromNativeSnapshot(snapshot)
      const trackSignature = `${snapshot.audio.length}:${snapshot.selectedAudioId || ""}|${snapshot.subtitles.length}:${snapshot.selectedSubtitleId || ""}`
      if (event === "playing" || snapshot.error) {
        log.info("[xt:playback] native state", {
          event,
          loaded: snapshot.loaded,
          paused: snapshot.paused,
          currentTime: snapshot.currentTime,
          duration: snapshot.duration,
          audio: snapshot.audio.length,
          subtitles: snapshot.subtitles.length,
          error: snapshot.error,
        })
      }
      if (trackSignature !== this.lastTrackSignature) {
        this.lastTrackSignature = trackSignature
        log.info("[xt:playback] native tracks", {
          audio: snapshot.audio.map((track) => ({
            id: track.id,
            label: track.label,
            language: track.language,
            selected: track.selected,
          })),
          subtitles: snapshot.subtitles.map((track) => ({
            id: track.id,
            label: track.label,
            language: track.language,
            selected: track.selected,
          })),
          selectedAudioId: snapshot.selectedAudioId,
          selectedSubtitleId: snapshot.selectedSubtitleId,
        })
      }
      this.emit(event, this.lastState)
      this.emit("tracks", this.lastState.tracks)
      this.renderNativeControls(this.lastState)
    } catch (error) {
      this.emitError(error)
    }
  }

  private ensureTrackBar(): HTMLElement | null {
    if (typeof document === "undefined") return null
    if (this.trackBarEl?.isConnected) return this.trackBarEl
    const host = this.videoEl.parentElement || document.body
    if (host !== document.body) {
      host.style.position = host.style.position || "relative"
    }
    const bar = document.createElement("div")
    bar.dataset.xtNativeTrackBar = "true"
    bar.className = "xt-native-playback-controls"
    Object.assign(bar.style, {
      position: host === document.body ? "fixed" : "absolute",
      left: host === document.body ? "calc(var(--sidebar-width, 332px) + 12px)" : "0",
      right: host === document.body ? "12px" : "0",
      bottom: "0",
      zIndex: "2147483647",
      display: "flex",
      alignItems: "center",
      flexWrap: "wrap",
      gap: "7px",
      minHeight: "86px",
      maxHeight: "112px",
      padding: "8px 10px",
      color: "white",
      background: "linear-gradient(180deg, rgba(10,16,22,0.84), rgba(5,8,12,0.96))",
      pointerEvents: "auto",
      boxSizing: "border-box",
      fontSize: "12px",
      overflow: "visible",
      border: "1px solid rgba(255,255,255,0.12)",
      borderBottom: "0",
      borderRadius: "12px 12px 0 0",
      boxShadow: "0 -18px 48px rgba(0,0,0,0.42)",
    })
    host.appendChild(bar)
    this.trackBarEl = bar
    return bar
  }

  private removeTrackBar(): void {
    this.trackBarEl?.remove()
    this.trackBarEl = null
  }

  private renderNativeControls(state: PlaybackState): void {
    const bar = this.ensureTrackBar()
    if (!bar) return
    const tracks = state.tracks
    const hasAudioChoices = tracks.audio.length > 1
    const hasSubtitleChoices = tracks.subtitles.length > 0
    bar.replaceChildren()

    const playButton = this.createControlButton(state.paused === false ? "Pause" : "Play")
    playButton.addEventListener("click", () => {
      if (this.getState().paused === false) {
        this.pause()
      } else {
        void this.play()
      }
    })
    bar.appendChild(playButton)

    const duration = Number.isFinite(state.duration) ? Math.max(0, state.duration) : 0
    const currentTime = Number.isFinite(state.currentTime)
      ? Math.max(0, Math.min(state.currentTime, duration || state.currentTime))
      : 0
    const time = document.createElement("span")
    time.textContent = `${formatPlaybackTime(currentTime)} / ${duration ? formatPlaybackTime(duration) : "--:--"}`
    time.style.whiteSpace = "nowrap"
    bar.appendChild(time)

    const seeker = document.createElement("input")
    seeker.type = "range"
    seeker.min = "0"
    seeker.max = String(Math.max(1, duration || 1))
    seeker.step = "1"
    seeker.value = String(currentTime)
    seeker.disabled = duration <= 0
    Object.assign(seeker.style, {
      flex: "1 1 180px",
      minWidth: "120px",
      accentColor: "#45c8f0",
      pointerEvents: "auto",
    })
    seeker.addEventListener("change", () => this.seek(Number(seeker.value) || 0))
    bar.appendChild(seeker)

    const volume = document.createElement("input")
    volume.type = "range"
    volume.min = "0"
    volume.max = "100"
    volume.step = "1"
    volume.value = "100"
    volume.title = "Volume"
    Object.assign(volume.style, {
      width: "86px",
      accentColor: "#45c8f0",
      pointerEvents: "auto",
    })
    volume.addEventListener("change", () => this.setVolume(Number(volume.value) || 0))
    bar.appendChild(volume)

    bar.appendChild(
      this.createTrackSelect(
        "Audio",
        tracks.audio.length > 0
          ? tracks.audio
          : [
              {
                id: "",
                kind: "audio",
                label: "No audio",
                language: "",
                index: -1,
                active: false,
              },
            ],
        tracks.selectedAudioId || tracks.audio[0]?.id || "",
        (id) => {
          if (id && hasAudioChoices) this.selectAudioTrack(id)
        },
        !hasAudioChoices,
      ),
    )

    const subtitleRows = [
      {
        id: "",
        kind: "subtitle" as const,
        label: hasSubtitleChoices ? "Off" : "No subs",
        language: "",
        index: -1,
        active: !tracks.selectedSubtitleId,
      },
      ...tracks.subtitles,
    ]
    bar.appendChild(
      this.createTrackSelect(
        "Subs",
        subtitleRows,
        tracks.selectedSubtitleId || "",
        (id) => {
          if (hasSubtitleChoices) this.selectSubtitleTrack(id || null)
        },
        !hasSubtitleChoices,
      ),
    )

    bar.appendChild(this.createSpeedSelect())

    const fullscreen = this.createControlButton("Full")
    fullscreen.addEventListener("click", () => {
      void this.toggleFullscreen()
    })
    bar.appendChild(fullscreen)

    const mini = this.createControlButton(this.miniMode ? "Dock" : "Mini")
    mini.addEventListener("click", () => this.toggleMiniMode())
    bar.appendChild(mini)
  }

  private createControlButton(label: string): HTMLButtonElement {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = label
    Object.assign(button.style, {
      border: "1px solid rgba(255,255,255,0.28)",
      borderRadius: "8px",
      background: "rgba(255,255,255,0.12)",
      color: "white",
      padding: "6px 8px",
      font: "inherit",
      cursor: "pointer",
      pointerEvents: "auto",
      whiteSpace: "nowrap",
    })
    return button
  }

  private createTrackSelect(
    label: string,
    tracks: PlaybackTrack[],
    selectedId: string | null,
    onChange: (id: string) => void,
    disabled = false,
  ): HTMLElement {
    const wrap = document.createElement("label")
    Object.assign(wrap.style, {
      display: "flex",
      alignItems: "center",
      gap: "4px",
      whiteSpace: "nowrap",
    })
    const text = document.createElement("span")
    text.textContent = label
    const select = document.createElement("select")
    Object.assign(select.style, {
      maxWidth: "132px",
      border: "1px solid rgba(255,255,255,0.25)",
      borderRadius: "7px",
      background: "rgba(0,0,0,0.86)",
      color: "white",
      padding: "5px",
      pointerEvents: "auto",
    })
    select.disabled = disabled
    if (disabled) select.style.opacity = "0.55"
    for (const track of tracks) {
      const option = document.createElement("option")
      option.value = track.id
      option.textContent = track.label || `${label} ${track.index + 1}`
      option.selected = track.id === selectedId
      select.appendChild(option)
    }
    select.addEventListener("change", () => onChange(select.value))
    wrap.append(text, select)
    return wrap
  }

  private createSpeedSelect(): HTMLElement {
    const speeds = [0.5, 0.75, 1, 1.25, 1.5, 2]
    return this.createTrackSelect(
      "Speed",
      speeds.map((speed, index) => ({
        id: String(speed),
        kind: "audio" as const,
        label: `${speed}x`,
        language: "",
        index,
        active: speed === 1,
      })),
      String(this.playbackRate),
      (id) => this.setPlaybackRate(Number(id) || 1),
    )
  }

  private toggleMiniMode(): void {
    const parent = this.videoEl.parentElement
    if (!parent) return
    this.miniMode = !this.miniMode
    if (this.miniMode) {
      parent.dataset.xtNativeMini = "true"
      Object.assign(parent.style, {
        position: "fixed",
        right: "18px",
        bottom: "118px",
        width: "420px",
        maxWidth: "42vw",
        zIndex: "2147483600",
        boxShadow: "0 20px 60px rgba(0,0,0,0.45)",
      })
    } else {
      delete parent.dataset.xtNativeMini
      parent.style.removeProperty("position")
      parent.style.removeProperty("right")
      parent.style.removeProperty("bottom")
      parent.style.removeProperty("width")
      parent.style.removeProperty("max-width")
      parent.style.removeProperty("z-index")
      parent.style.removeProperty("box-shadow")
    }
    window.setTimeout(() => {
      void this.attachSurface()
      this.renderNativeControls(this.getState())
    }, 0)
  }

  private async toggleFullscreen(): Promise<void> {
    try {
      const mod = await import("@tauri-apps/api/window")
      const appWindow = mod.getCurrentWindow()
      const isFullscreen = await appWindow.isFullscreen()
      await appWindow.setFullscreen(!isFullscreen)
      window.setTimeout(() => {
        void this.attachSurface()
        this.renderNativeControls(this.getState())
      }, 100)
    } catch (error) {
      log.warn("[xt:playback] native fullscreen toggle failed", error)
      void this.nativeElement().parentElement?.requestFullscreen?.()
    }
  }

  private startPolling(): void {
    if (typeof window === "undefined") return
    this.stopPolling()
    this.pollTimer = window.setInterval(() => {
      void this.refreshState("timeupdate")
    }, 1000)
  }

  private stopPolling(): void {
    if (this.pollTimer == null) return
    window.clearInterval(this.pollTimer)
    this.pollTimer = null
  }

  private emitError(error: unknown): void {
    this.lastState = {
      ...this.getState(),
      error,
    }
    this.emit("error", this.lastState)
  }

  private emit(event: string, payload: unknown): void {
    this.listeners.get(event)?.forEach((listener) => {
      try {
        listener(payload)
      } catch (error) {
        log.warn("[xt:playback] native listener failed", error)
      }
    })
    try {
      document.dispatchEvent(
        new CustomEvent(`xt:playback:${event}`, {
          detail: {
            backend: this.nativeStatus.backend,
            kind: this.kind,
            payload,
          },
        }),
      )
    } catch {
      // Tests and non-document contexts may not allow DOM events.
    }
  }
}

function emptyTracks(): PlaybackTracksState {
  return {
    audio: [],
    subtitles: [],
    selectedAudioId: null,
    selectedSubtitleId: null,
  }
}

function formatPlaybackTime(seconds: number): string {
  const total = Math.max(0, Math.floor(Number(seconds) || 0))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const secs = total % 60
  const mm = String(minutes).padStart(hours > 0 ? 2 : 1, "0")
  const ss = String(secs).padStart(2, "0")
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`
}

function stateFromNativeSnapshot(snapshot: NativePlaybackSnapshot): PlaybackState {
  return {
    backend: "native",
    currentTime: Number(snapshot.currentTime) || 0,
    duration: Number(snapshot.duration) || 0,
    paused: Boolean(snapshot.paused),
    ended: Boolean(snapshot.ended),
    error: snapshot.error || null,
    tracks: {
      audio: Array.isArray(snapshot.audio) ? snapshot.audio : [],
      subtitles: Array.isArray(snapshot.subtitles) ? snapshot.subtitles : [],
      selectedAudioId: snapshot.selectedAudioId || null,
      selectedSubtitleId: snapshot.selectedSubtitleId || null,
    },
  }
}

export async function mountWebPlaybackSession(
  videoEl: HTMLVideoElement,
  backend: PlayerBackend,
  options: PlaybackSessionOptions = {},
  nativeStatus: NativePlaybackStatus | null = null,
): Promise<WebPlaybackSession | null> {
  const mounted = await mountPlayer(videoEl, backend, options)
  if (mounted.kind !== "embedded") {
    log.warn("[xt:playback] non-web mounted result ignored by WebPlaybackSession", {
      backend: mounted.backend,
    })
    return null
  }
  return new WebPlaybackSession(mounted, nativeStatus)
}

export async function mountPlaybackSession(
  videoEl: HTMLVideoElement,
  backend: PlayerBackend,
  options: PlaybackSessionOptions = {},
): Promise<PlaybackSession | null> {
  const nativeStatus = options.nativeStatus ?? await getNativePlaybackStatus()
  const invoke = nativeStatus?.available ? await getTauriInvoke() : null
  if (isNativeIntegratedPlaybackAvailable(nativeStatus) && invoke) {
    return new NativePlaybackSession(videoEl, invoke, nativeStatus)
  }
  if (nativeStatus?.available) {
    log.info("[xt:playback] native backend available but not selectable yet", {
      backend: nativeStatus.backend,
      reason: nativeStatus.reason,
      nextStep: nativeStatus.nextStep,
    })
  }
  return mountWebPlaybackSession(videoEl, backend, options, nativeStatus)
}
