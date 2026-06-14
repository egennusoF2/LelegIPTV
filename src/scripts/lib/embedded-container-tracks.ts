/**
 * Dev-only: expose MKV/MP4 embedded audio & subtitle tracks via ffprobe/ffmpeg
 * (browser <video> cannot list them natively).
 */
import { log, redactUrl } from "@/scripts/lib/log.js"
import { t } from "@/scripts/lib/i18n.js"
import { resolveMediaHeaders } from "@/scripts/lib/embedded-media-fetch.js"
import {
  devProxyFetchHeaders,
  isContainerUrl,
  resolveEmbeddedStreamUrl,
  resolveNativeStreamProxyUrl,
  useDevStreamProxy,
  useNativeStreamProxy,
  vodAssetPathKey,
} from "@/scripts/lib/stream-proxy"
import {
  removeNativeTrackSettings,
} from "@/scripts/lib/embedded-native-tracks.js"
import {
  clearTrackPreference,
  findPreferredTrackIndex,
  saveTrackPreference,
} from "@/scripts/lib/media-track-preferences"
import {
  formatContainerAudioLabel,
  formatContainerSubtitleLabel,
} from "@/scripts/lib/media-track-labels.js"
import {
  trackSettingsDebug,
  markContainerPlaybackGuard,
  clearContainerPlaybackGuard,
  type ArtplayerSelectorRow,
} from "@/scripts/lib/artplayer-track-settings.js"
import { VttStreamParser } from "@/scripts/lib/vtt-stream-parser.js"

const VOD_STREAMS_PATH = "/__vod_streams"
const VOD_REMUX_PATH = "/__vod_remux"
const VOD_HLS_PATH = "/__vod_hls"
const SETTING_AUDIO = "xt-container-audio"
const SETTING_SUBTITLE = "xt-container-subtitle"

export interface ContainerAudioTrack {
  index: number
  language?: string
  label?: string
  codec?: string
}

export interface ContainerSubtitleTrack {
  index: number
  language?: string
  label?: string
  codec?: string
  src: string
}

interface ContainerStreamsPayload {
  audio?: ContainerAudioTrack[]
  subtitles?: ContainerSubtitleTrack[]
  error?: string
}

export function wrapVodRemuxUrl(sourceUrl: string, audioIndex: number): string {
  return `${VOD_REMUX_PATH}?url=${encodeURIComponent(sourceUrl)}&audio=${audioIndex}`
}

export function wrapVodHlsUrl(sourceUrl: string, audioIndex: number): string {
  return `${VOD_HLS_PATH}?url=${encodeURIComponent(sourceUrl)}&audio=${audioIndex}`
}

function wrapVodRemuxWaitUrl(remuxBase: string): string {
  const sep = remuxBase.includes("?") ? "&" : "?"
  return `${remuxBase}${sep}wait=1`
}

function wrapVodRemuxStatusUrl(remuxBase: string): string {
  const sep = remuxBase.includes("?") ? "&" : "?"
  return `${remuxBase}${sep}status=1`
}

function withWaitParam(url: string): string {
  return url.includes("?") ? `${url}&wait=1` : `${url}?wait=1`
}

const REMUX_WAIT_MS = 20 * 60_000

function abortAudioSwitch(art: any): void {
  if (art._xtAudioSwitchAbort) {
    try {
      art._xtAudioSwitchAbort.abort()
    } catch {}
    art._xtAudioSwitchAbort = null
  }
  if (typeof art._xtAudioSwitchCleanup === "function") {
    try {
      art._xtAudioSwitchCleanup()
    } catch {}
    art._xtAudioSwitchCleanup = null
  }
}

function setArtplayerNativeSource(art: any, video: HTMLVideoElement, url: string): void {
  art.type = "xt-native"
  art.url = url
  try {
    if (video.src !== url) video.src = url
    video.load()
  } catch {}
}

function isAudioSwitchStale(art: any, gen: number): boolean {
  return gen !== art._xtAudioSwitchGen
}

async function probeRemuxCacheReady(
  remuxBase: string,
  sourceUrl: string,
  signal?: AbortSignal,
): Promise<boolean> {
  const headers = resolveMediaHeaders(sourceUrl)
  try {
    const response = await fetch(wrapVodRemuxStatusUrl(remuxBase), {
      headers: devProxyFetchHeaders(headers),
      signal,
    })
    if (!response.ok) return false
    const payload = (await response.json()) as { ready?: boolean }
    return payload.ready === true
  } catch {
    return false
  }
}

function playbackOffset(art: any): number {
  return Number.isFinite(art?._xtPlaybackOffsetSeconds)
    ? Number(art._xtPlaybackOffsetSeconds)
    : 0
}

function absolutePlaybackTime(art: any, video: HTMLVideoElement): number {
  const raw =
    Number.isFinite(art?.currentTime) && art.currentTime > 0
      ? art.currentTime
      : Number.isFinite(video.currentTime)
        ? video.currentTime
        : 0
  return playbackOffset(art) + raw
}

function setArtplayerTsSource(
  art: any,
  video: HTMLVideoElement,
  url: string,
  startSeconds = 0,
): void {
  art._xtTranscodeSrcUrl =
    (typeof art._xtContainerSourceUrl === "string" && art._xtContainerSourceUrl) ||
    (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
    ""
  art._xtPlaybackOffsetSeconds =
    Number.isFinite(startSeconds) && startSeconds > 0 ? startSeconds : 0
  art._xtVirtualTimelineInstalled = true
  art.type = "ts"
  art.url = url
  try {
    if (video.src !== url) video.src = url
    video.load()
  } catch {}
}

function isTauriTranscodeUrl(url: string): boolean {
  return /\/__transcode(?:\?|$)/i.test(url)
}

async function resolveTauriTranscodeUrl(
  sourceUrl: string,
  audioIndex: number,
  startSeconds = 0,
): Promise<string | null> {
  if (!useNativeStreamProxy() || !sourceUrl) return null
  try {
    const { invoke } = await import("@tauri-apps/api/core")
    let referer = ""
    try {
      referer = `${new URL(sourceUrl).origin}/`
    } catch {}
    return await invoke<string>("transcode_proxy_url", {
      url: sourceUrl,
      userAgent: "VLC/3.0.20 LibVLC/3.0.20",
      referer: referer || undefined,
      audioIndex,
      startSeconds: Number.isFinite(startSeconds) ? Math.max(0, startSeconds) : 0,
    })
  } catch (error) {
    log.warn("[xt:container-tracks] transcode URL failed", error)
    return null
  }
}

async function waitForVodRemuxComplete(
  remuxBase: string,
  sourceUrl: string,
  signal?: AbortSignal,
): Promise<void> {
  const headers = resolveMediaHeaders(sourceUrl)
  const waitUrl = wrapVodRemuxWaitUrl(remuxBase)
  const timeout = new AbortController()
  const timer = setTimeout(() => timeout.abort(), REMUX_WAIT_MS)
  const onParentAbort = () => timeout.abort()
  if (signal) {
    if (signal.aborted) {
      clearTimeout(timer)
      throw new DOMException("Aborted", "AbortError")
    }
    signal.addEventListener("abort", onParentAbort, { once: true })
  }
  try {
    const response = await fetch(waitUrl, {
      headers: devProxyFetchHeaders(headers),
      signal: timeout.signal,
    })
    if (!response.ok && response.status !== 204) {
      throw new Error(`remux wait HTTP ${response.status}`)
    }
  } finally {
    clearTimeout(timer)
    if (signal) signal.removeEventListener("abort", onParentAbort)
  }
}

async function waitForGeneratedVodReady(
  generatedBase: string,
  sourceUrl: string,
  signal?: AbortSignal,
): Promise<void> {
  const timeout = new AbortController()
  const timer = setTimeout(() => timeout.abort(), REMUX_WAIT_MS)
  const onParentAbort = () => timeout.abort()
  if (signal) {
    if (signal.aborted) {
      clearTimeout(timer)
      throw new DOMException("Aborted", "AbortError")
    }
    signal.addEventListener("abort", onParentAbort, { once: true })
  }
  try {
    const response = await fetch(
      withWaitParam(generatedBase),
      containerApiFetchInit(sourceUrl, timeout.signal),
    )
    if (!response.ok && response.status !== 204) {
      throw new Error(`generated vod wait HTTP ${response.status}`)
    }
  } finally {
    clearTimeout(timer)
    if (signal) signal.removeEventListener("abort", onParentAbort)
  }
}

/** Warm remux cache in background (dev proxy ffmpeg). */
function prefetchContainerRemux(sourceUrl: string, audioIndex: number): void {
  if (audioIndex === 0) return
  const remuxBase = absoluteAssetUrl(wrapVodRemuxUrl(sourceUrl, audioIndex))
  void waitForVodRemuxComplete(remuxBase, sourceUrl).catch(() => {})
}

function isRemuxDecodeError(video: HTMLVideoElement): boolean {
  const code = video.error?.code
  return code === 3 || code === 4
}

const STREAM_PROBE_MS = 25_000

function shortTrackHint(value: string): string {
  const clean = String(value || "").trim()
  if (!clean) return ""
  return clean.length > 28 ? `${clean.slice(0, 25)}...` : clean
}

function settingTitle(title: string, hint: string): string {
  const compact = shortTrackHint(hint)
  return compact
    ? `${title} <span class="opacity-70 text-2xs">· ${compact}</span>`
    : title
}

/** ArtPlayer appends `onSelect` return values into the row — always return the full row HTML. */
function removeArtplayerSetting(art: any, name: string): void {
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      art.setting.remove(name)
    } catch {
      break
    }
  }
}

function subtitleSettingHtml(
  track: ContainerSubtitleTrack | null,
  listIndex: number,
): string {
  const menu = t("player.menu.subtitle") || "Subtitles"
  if (!track || listIndex < 0) {
    return settingTitle(menu, t("player.subtitle.off") || "Off")
  }
  return settingTitle(
    menu,
    formatContainerSubtitleLabel(
      {
        index: track.index,
        language: track.language,
        label: track.label,
        codec: track.codec,
      },
      listIndex,
    ),
  )
}

function audioSettingHtml(
  track: ContainerAudioTrack | null,
  listPosition: number,
): string {
  const menu = t("player.menu.audio") || "Audio"
  if (!track) return menu
  return settingTitle(menu, formatContainerAudioLabel(track, listPosition))
}

function replaceXtSubtitleTrackElement(
  art: any,
  video: HTMLVideoElement,
  name: string,
  language: string,
): HTMLTrackElement {
  video.querySelectorAll("track[data-xt-sub]").forEach((node) => node.remove())
  if (art._xtProgrammaticTextTrack) {
    try {
      art._xtProgrammaticTextTrack = null
    } catch {}
  }
  const $track = document.createElement("track")
  $track.dataset.xtSub = "1"
  $track.kind = "subtitles"
  $track.label = name
  if (language) $track.srclang = language
  // No `src` here — an empty/data VTT load would wipe programmatic cues.
  video.insertBefore($track, video.firstChild)
  if (art?.template) {
    art.template.$track = $track
  }
  art._xtProgrammaticTextTrack = null
  return $track
}

function resolveXtTextTrack(
  art: any,
  video: HTMLVideoElement,
  $track: HTMLTrackElement,
  name: string,
  language: string,
): TextTrack {
  if ($track.track) return $track.track
  const added = video.addTextTrack("subtitles", name, language || "und")
  art._xtProgrammaticTextTrack = added
  return added
}

function findCuesAtTime(textTrack: TextTrack, time: number): VTTCue[] {
  const list = textTrack.cues
  if (!list) return []
  const hits: VTTCue[] = []
  for (const raw of Array.from(list)) {
    const cue = raw as VTTCue
    if (time >= cue.startTime && time < cue.endTime) hits.push(cue)
  }
  return hits
}

function cancelSubtitleStreamReader(art: any): void {
  if (art._xtSubtitleStreamReader) {
    void art._xtSubtitleStreamReader.cancel().catch(() => {})
    art._xtSubtitleStreamReader = null
  }
}

/** Cancel any in-flight subtitle fetch/extract (call before starting a new apply). */
function abortSubtitleFetch(art: any): void {
  cancelSubtitleStreamReader(art)
  if (art._xtSubtitleFetchAbort) {
    try {
      art._xtSubtitleFetchAbort.abort()
    } catch {}
    art._xtSubtitleFetchAbort = null
  }
}

const EMPTY_VTT =
  "data:text/vtt;charset=utf-8,WEBVTT%0A%0A"

function findXtSubtitleTrack(video: HTMLVideoElement): HTMLTrackElement | null {
  return video.querySelector("track[data-xt-sub]")
}

function getXtSubtitleTrackElement(
  art: any,
  video: HTMLVideoElement,
): HTMLTrackElement | null {
  const fromTemplate = art?.template?.$track as HTMLTrackElement | undefined
  if (fromTemplate && video.contains(fromTemplate)) return fromTemplate
  return findXtSubtitleTrack(video)
}

function getXtTextTrack(art: any, video: HTMLVideoElement): TextTrack | null {
  const fromElement = getXtSubtitleTrackElement(art, video)?.track
  if (fromElement) return fromElement
  return (art?._xtProgrammaticTextTrack as TextTrack | undefined) ?? null
}

function finalizeXtSubtitleDisplay(
  art: any,
  video: HTMLVideoElement,
  $track: HTMLTrackElement,
  gen: number,
): boolean {
  if (isSubtitleApplyStale(art, gen)) return false
  wireArtplayerSubtitleTrack(art, video, $track)
  renderXtSubtitleOverlay(art, video)
  scheduleXtSubtitleOverlayRetries(art, video)
  const textTrack = getXtTextTrack(art, video)
  trackSettingsDebug("container.subtitle.ready", {
    gen,
    cues: textTrack?.cues?.length ?? 0,
    activeCues: textTrack?.activeCues?.length ?? 0,
    currentTime: video.currentTime,
  })
  return true
}

/** ArtPlayer `subtitle.update()` reads `video.textTracks[0]` — we render from our track instead. */
function renderXtSubtitleOverlay(art: any, video: HTMLVideoElement): void {
  const $subtitle = art?.template?.$subtitle as HTMLElement | undefined
  if (!$subtitle) return

  const textTrack = getXtTextTrack(art, video)
  if (!textTrack) {
    $subtitle.innerHTML = ""
    return
  }

  for (const tr of Array.from(video.textTracks || [])) {
    if (tr !== textTrack) {
      tr.mode = "disabled"
    }
  }
  textTrack.mode = "hidden"

  let cues: VTTCue[] = []
  const offset = playbackOffset(art)
  const timelineTime =
    art?._xtVirtualTimelineInstalled &&
    Number.isFinite(art?._xtExpectedDurationSeconds) &&
    Number(art._xtExpectedDurationSeconds) > 0
      ? video.currentTime
      : offset + video.currentTime
  const active = offset > 0.5 || art?._xtVirtualTimelineInstalled ? null : textTrack.activeCues
  if (active && active.length > 0) {
    cues = Array.from(active) as VTTCue[]
  } else {
    cues = findCuesAtTime(textTrack, timelineTime)
  }
  if (cues.length === 0) {
    $subtitle.innerHTML = ""
    return
  }

  try {
    $subtitle.style.display = ""
    $subtitle.style.opacity = "1"
  } catch {}

  const escapeHtml = art?.option?.subtitle?.escape !== false
  const escape = (line: string) => {
    if (!escapeHtml) return line
    const div = document.createElement("div")
    div.textContent = line
    return div.innerHTML
  }

  $subtitle.innerHTML = cues
    .map((cue, index) => {
      const text = cue.text || ""
      return text
        .split(/\r?\n/)
        .filter((line) => line.trim())
        .map(
          (line) =>
            `<div class="art-subtitle-line" data-group="${index}">${escape(line)}</div>`,
        )
        .join("")
    })
    .join("")
}

/** Call before first `video.src` so later subtitle changes do not reload the media element. */
export function bootstrapArtplayerSubtitleTrack(
  art: any,
  video: HTMLVideoElement,
): void {
  let $track = getXtSubtitleTrackElement(art, video)
  if (!$track) {
    $track = document.createElement("track")
    $track.dataset.xtSub = "1"
    $track.kind = "subtitles"
    $track.label = "xt"
    $track.default = true
    $track.src = EMPTY_VTT
    video.insertBefore($track, video.firstChild)
  }
  if ($track.kind !== "subtitles") {
    $track.kind = "subtitles"
  }
  if (art?.template) {
    art.template.$track = $track
  }
  wireArtplayerSubtitleTrack(art, video, $track)
}

function wireArtplayerSubtitleTrack(
  art: any,
  video: HTMLVideoElement,
  $track: HTMLTrackElement,
): void {
  if (art?.template) {
    art.template.$track = $track
  }
  if (!$track.track) return

  const sub = art?.subtitle
  if (sub) {
    try {
      art.events.remove(sub.destroyEvent)
    } catch {}
    sub.destroyEvent = art.events.proxy($track.track, "cuechange", () => {
      renderXtSubtitleOverlay(art, video)
    })
  }

  if (!art._xtSubtitleTimeupdate) {
    art._xtSubtitleTimeupdate = () => renderXtSubtitleOverlay(art, video)
    art.on("video:timeupdate", art._xtSubtitleTimeupdate)
  }
}

function capturePlaybackState(video: HTMLVideoElement, art: any): {
  resumeAt: number
  wasPlaying: boolean
} {
  const resumeAt =
    absolutePlaybackTime(art, video)
  return { resumeAt, wasPlaying: !video.paused }
}

function restorePlaybackState(
  art: any,
  video: HTMLVideoElement,
  resumeAt: number,
  wasPlaying: boolean,
): void {
  const targetTime =
    art?._xtVirtualTimelineInstalled
      ? Math.max(0, resumeAt)
      : Math.max(0, resumeAt - playbackOffset(art))
  if (resumeAt > 0.5 && Math.abs(video.currentTime - targetTime) > 0.75) {
    try {
      video.currentTime = targetTime
    } catch {}
    try {
      art.currentTime = targetTime
    } catch {}
    trackSettingsDebug("container.playback.restore", {
      resumeAt,
      after: playbackOffset(art) + video.currentTime,
    })
  }
  if (wasPlaying && video.paused) {
    void art.play?.()?.catch(() => {})
  }
}

const SUBTITLE_EXTRACT_WAIT_MS = 90_000
const SUBTITLE_CUES_WAIT_MS = 30_000
const SUBTITLE_OVERLAY_RETRY_MS = 8_000
const SUBTITLE_NOTICE_REFRESH_MS = 2_000
const TRACK_ATTACH_RETRY_MS = [2_500, 7_500, 15_000]

function wrapSubtitleWaitUrl(subtitlePath: string): string {
  return subtitlePath.includes("?") ? `${subtitlePath}&wait=1` : `${subtitlePath}?wait=1`
}

function wrapSubtitleStatusUrl(subtitlePath: string): string {
  return subtitlePath.includes("?") ? `${subtitlePath}&status=1` : `${subtitlePath}?status=1`
}

async function probeSubtitleCacheReady(
  subtitlePath: string,
  sourceUrl: string,
  signal?: AbortSignal,
): Promise<boolean> {
  try {
    const response = await fetch(
      await containerApiUrl(wrapSubtitleStatusUrl(subtitlePath), sourceUrl),
      containerApiFetchInit(sourceUrl, signal),
    )
    if (!response.ok) return false
    const payload = (await response.json()) as { ready?: boolean }
    return payload.ready === true
  } catch {
    return false
  }
}

function startSubtitleLoadingNotice(
  art: any,
  message: string,
  gen: number,
): () => void {
  const show = () => {
    if (!art._xtSubtitleApplyInFlight || isSubtitleApplyStale(art, gen)) return
    try {
      art.notice.show = message
    } catch {}
  }
  show()
  const timer = setInterval(show, SUBTITLE_NOTICE_REFRESH_MS)
  return () => clearInterval(timer)
}

function isTrackReadyWithCues($track: HTMLTrackElement): boolean {
  if ($track.readyState === HTMLTrackElement.ERROR) return false
  if ($track.readyState < HTMLTrackElement.LOADED) return false
  return ($track.track?.cues?.length ?? 0) > 0
}

/** Wait until the track element has parsed VTT cues (not just the previous empty placeholder). */
function waitForSubtitleTrackReady(
  $track: HTMLTrackElement,
  timeoutMs = SUBTITLE_CUES_WAIT_MS,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs
    let pollTimer: ReturnType<typeof setTimeout> | undefined

    const cleanup = () => {
      if (pollTimer !== undefined) clearTimeout(pollTimer)
      $track.removeEventListener("load", onTrackLoad)
      $track.removeEventListener("error", onTrackError)
    }

    const finishOk = () => {
      cleanup()
      resolve()
    }
    const finishErr = (message: string) => {
      cleanup()
      reject(new Error(message))
    }

    const tryFinish = () => {
      if ($track.readyState === HTMLTrackElement.ERROR) {
        finishErr("subtitle track load failed")
        return
      }
      if (isTrackReadyWithCues($track)) {
        finishOk()
        return
      }
      if (Date.now() >= deadline) {
        finishErr("subtitle cues not ready")
        return
      }
      pollTimer = setTimeout(tryFinish, 50)
    }

    const onTrackLoad = () => tryFinish()
    const onTrackError = () => finishErr("subtitle track load failed")

    $track.addEventListener("load", onTrackLoad)
    $track.addEventListener("error", onTrackError, { once: true })
    pollTimer = setTimeout(tryFinish, 50)
  })
}

function scheduleXtSubtitleOverlayRetries(art: any, video: HTMLVideoElement): void {
  if (art._xtSubtitleOverlayRetryTimer) {
    clearTimeout(art._xtSubtitleOverlayRetryTimer)
  }
  const started = Date.now()
  const tick = () => {
    renderXtSubtitleOverlay(art, video)
    if (Date.now() - started < SUBTITLE_OVERLAY_RETRY_MS) {
      art._xtSubtitleOverlayRetryTimer = setTimeout(tick, 120)
    } else {
      art._xtSubtitleOverlayRetryTimer = undefined
    }
  }
  requestAnimationFrame(tick)
}

function activateXtSubtitleTrack(
  art: any,
  video: HTMLVideoElement,
  $track: HTMLTrackElement,
  blobUrl: string,
  name: string,
): void {
  wireArtplayerSubtitleTrack(art, video, $track)
  if (art?.subtitle) {
    art.subtitle.option = {
      ...(art.option?.subtitle || {}),
      url: blobUrl,
      name,
      type: "vtt",
    }
  }
  renderXtSubtitleOverlay(art, video)
  scheduleXtSubtitleOverlayRetries(art, video)
}

async function applySubtitleTrackUrl(
  art: any,
  video: HTMLVideoElement,
  blobUrl: string,
  name: string,
  language = "",
): Promise<void> {
  const $track = replaceXtSubtitleTrackElement(art, video, name, language)
  await loadXtSubtitleFromBlob(art, video, $track, blobUrl, name, language)
  activateXtSubtitleTrack(art, video, $track, blobUrl, name)
}

function clearArtplayerSubtitleOverlay(art: any, video: HTMLVideoElement): void {
  const $track = findXtSubtitleTrack(video)
  if ($track?.track) {
    $track.track.mode = "disabled"
  }
  try {
    art.template.$subtitle.innerHTML = ""
  } catch {}
}

function revokeSubtitleBlob(art: any): void {
  const prev = art._xtSubtitleBlobUrl
  if (typeof prev === "string" && prev.startsWith("blob:")) {
    try {
      URL.revokeObjectURL(prev)
    } catch {}
  }
  art._xtSubtitleBlobUrl = ""
}

async function waitForSubtitleExtract(
  subtitlePath: string,
  sourceUrl: string,
  signal?: AbortSignal,
): Promise<void> {
  const waitUrl = wrapSubtitleWaitUrl(subtitlePath)
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), SUBTITLE_EXTRACT_WAIT_MS)
  const onParentAbort = () => controller.abort()
  if (signal) {
    if (signal.aborted) {
      clearTimeout(timeout)
      throw new DOMException("Aborted", "AbortError")
    }
    signal.addEventListener("abort", onParentAbort, { once: true })
  }
  try {
    const response = await fetch(
      await containerApiUrl(waitUrl, sourceUrl),
      containerApiFetchInit(sourceUrl, controller.signal),
    )
    if (!response.ok && response.status !== 204) {
      throw new Error(`subtitle extract wait HTTP ${response.status}`)
    }
  } finally {
    clearTimeout(timeout)
    if (signal) signal.removeEventListener("abort", onParentAbort)
  }
}

function clearTextTrackCues(textTrack: TextTrack): void {
  const cues = textTrack.cues
  if (!cues) return
  for (let i = cues.length - 1; i >= 0; i--) {
    const cue = cues[i]
    if (cue) textTrack.removeCue(cue)
  }
}

function applyParsedCuesToTextTrack(
  textTrack: TextTrack,
  vttBody: string,
  onFirstCue?: () => void,
): number {
  clearTextTrackCues(textTrack)
  let cueCount = 0
  const parser = new VttStreamParser()
  parser.onCue = (cue) => {
    try {
      textTrack.addCue(new VTTCue(cue.start, cue.end, cue.text))
      cueCount++
      if (cueCount === 1) onFirstCue?.()
    } catch {
      // overlapping cues on some engines
    }
  }
  parser.push(vttBody)
  parser.finish()
  return cueCount
}

/** Load full VTT via blob `src` (browser parser — most reliable for display). */
async function loadXtSubtitleFromBlob(
  art: any,
  video: HTMLVideoElement,
  $track: HTMLTrackElement,
  blobUrl: string,
  name: string,
  language = "",
): Promise<TextTrack> {
  const prev = art._xtSubtitleBlobUrl as string | undefined
  if (prev && prev !== blobUrl && prev.startsWith("blob:")) {
    try {
      URL.revokeObjectURL(prev)
    } catch {}
  }
  art._xtProgrammaticTextTrack = null
  if ($track.src && $track.src !== blobUrl) $track.removeAttribute("src")

  $track.kind = "subtitles"
  $track.label = name
  if (language) $track.srclang = language
  $track.src = blobUrl
  art._xtSubtitleBlobUrl = blobUrl

  await waitForSubtitleTrackReady($track)
  const textTrack = $track.track
  if (!textTrack) throw new Error("subtitle TextTrack missing after blob load")
  textTrack.mode = "hidden"
  return textTrack
}

/**
 * Stream VTT from dev proxy as ffmpeg extracts (same pipe as server cache).
 * First cues often within a few seconds; rest arrive while watching.
 */
async function applySubtitleStreamProgressive(
  art: any,
  video: HTMLVideoElement,
  track: ContainerSubtitleTrack,
  name: string,
  sourceUrl: string,
  signal: AbortSignal | undefined,
  gen: number,
  onFirstCue?: () => void,
): Promise<number> {
  revokeSubtitleBlob(art)
  art._xtSubtitleVttFull = ""

  const $track = replaceXtSubtitleTrackElement(
    art,
    video,
    name,
    track.language || "",
  )

  const textTrack = resolveXtTextTrack(
    art,
    video,
    $track,
    name,
    track.language || "",
  )
  clearTextTrackCues(textTrack)
  textTrack.mode = "hidden"

  const url = absoluteAssetUrl(track.src)
  const headers = resolveMediaHeaders(sourceUrl)
  const response = await fetch(url, {
    headers: devProxyFetchHeaders(headers),
    signal,
  })
  if (!response.ok) {
    throw new Error(`subtitle stream HTTP ${response.status}`)
  }
  if (!response.body) {
    throw new Error("subtitle stream not readable")
  }

  let cueCount = 0
  let fullText = ""
  const parser = new VttStreamParser()
  parser.onCue = (cue) => {
    if (isSubtitleApplyStale(art, gen)) return
    try {
      textTrack.addCue(new VTTCue(cue.start, cue.end, cue.text))
      cueCount++
      if (cueCount === 1) {
        wireArtplayerSubtitleTrack(art, video, $track)
        renderXtSubtitleOverlay(art, video)
        scheduleXtSubtitleOverlayRetries(art, video)
        onFirstCue?.()
        trackSettingsDebug("container.subtitle.first-cue", {
          lang: track.language,
          gen,
          start: cue.start,
        })
      }
    } catch {
      // overlapping cues on some engines
    }
  }

  const reader = response.body.getReader()
  art._xtSubtitleStreamReader = reader
  const decoder = new TextDecoder()
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      const chunk = decoder.decode(value, { stream: true })
      fullText += chunk
      parser.push(chunk)
      if (isSubtitleApplyStale(art, gen) || signal?.aborted) {
        await reader.cancel().catch(() => {})
        break
      }
    }
    fullText += decoder.decode()
    parser.finish()
  } finally {
    if (art._xtSubtitleStreamReader === reader) {
      art._xtSubtitleStreamReader = null
    }
    reader.releaseLock()
  }

  if (fullText.includes("WEBVTT")) {
    art._xtSubtitleVttFull = fullText
    try {
      const blobUrl = URL.createObjectURL(
        new Blob([fullText], { type: "text/vtt;charset=utf-8" }),
      )
      const loaded = await loadXtSubtitleFromBlob(
        art,
        video,
        $track,
        blobUrl,
        name,
        track.language || "",
      )
      cueCount = loaded.cues?.length ?? cueCount
      wireArtplayerSubtitleTrack(art, video, $track)
      renderXtSubtitleOverlay(art, video)
      scheduleXtSubtitleOverlayRetries(art, video)
    } catch (error) {
      if (cueCount === 0) throw error
      wireArtplayerSubtitleTrack(art, video, $track)
      renderXtSubtitleOverlay(art, video)
    }
  }

  return cueCount
}

async function reapplySubtitleFromStoredVtt(
  art: any,
  video: HTMLVideoElement,
): Promise<number> {
  const vtt = art._xtSubtitleVttFull as string | undefined
  const last = art._xtLastSubtitleTrack as ContainerSubtitleTrack | undefined
  if (!vtt || !last) return 0

  const name = last.label || last.language || "Subtitle"
  const $track = replaceXtSubtitleTrackElement(
    art,
    video,
    name,
    last.language || "",
  )
  try {
    const blobUrl =
      (typeof art._xtSubtitleBlobUrl === "string" && art._xtSubtitleBlobUrl) ||
      URL.createObjectURL(new Blob([vtt], { type: "text/vtt;charset=utf-8" }))
    if (!art._xtSubtitleBlobUrl) art._xtSubtitleBlobUrl = blobUrl
    const loaded = await loadXtSubtitleFromBlob(
      art,
      video,
      $track,
      blobUrl,
      name,
      last.language || "",
    )
    const count = loaded.cues?.length ?? 0
    if (count > 0) {
      wireArtplayerSubtitleTrack(art, video, $track)
      renderXtSubtitleOverlay(art, video)
      scheduleXtSubtitleOverlayRetries(art, video)
    }
    return count
  } catch {
    const textTrack = resolveXtTextTrack(
      art,
      video,
      $track,
      name,
      last.language || "",
    )
    textTrack.mode = "hidden"
    const count = applyParsedCuesToTextTrack(textTrack, vtt)
    if (count > 0) {
      wireArtplayerSubtitleTrack(art, video, $track)
      renderXtSubtitleOverlay(art, video)
      scheduleXtSubtitleOverlayRetries(art, video)
    }
    return count
  }
}

async function fetchSubtitleVttBlob(
  subtitlePath: string,
  sourceUrl: string,
  signal?: AbortSignal,
): Promise<{ blobUrl: string; vttText: string }> {
  const url = await containerApiUrl(subtitlePath, sourceUrl)
  const response = await fetch(url, containerApiFetchInit(sourceUrl, signal))
  if (!response.ok) {
    throw new Error(`subtitle HTTP ${response.status}`)
  }
  const blob = await response.blob()
  if (!blob.size) {
    throw new Error("subtitle empty")
  }
  const vttText = await blob.text()
  if (!vttText.includes("WEBVTT")) {
    throw new Error("subtitle invalid vtt")
  }
  return {
    blobUrl: URL.createObjectURL(
      new Blob([vttText], { type: "text/vtt;charset=utf-8" }),
    ),
    vttText,
  }
}

function absoluteAssetUrl(path: string): string {
  if (!path) return path
  if (/^https?:\/\//i.test(path)) return path
  try {
    return new URL(path, window.location.origin).href
  } catch {
    return path
  }
}

async function containerApiUrl(path: string, sourceUrl: string): Promise<string> {
  if (useNativeStreamProxy()) {
    try {
      const proxied = await resolveNativeStreamProxyUrl(sourceUrl)
      const origin = new URL(proxied).origin
      return `${origin}${path.startsWith("/") ? path : `/${path}`}`
    } catch {}
  }
  return absoluteAssetUrl(path)
}

function containerApiFetchInit(
  sourceUrl: string,
  signal?: AbortSignal,
): RequestInit {
  if (useNativeStreamProxy()) {
    return signal ? { signal } : {}
  }
  return {
    headers: devProxyFetchHeaders(resolveMediaHeaders(sourceUrl)),
    signal,
  }
}

/** Warm subtitle disk cache via `wait=1` (204 when ready — see tracce-audio doc / Megacubo lazy extract). */
function prefetchContainerSubtitle(
  sourceUrl: string,
  track: ContainerSubtitleTrack,
): void {
  if (!track?.src) return
  void containerApiUrl(wrapSubtitleWaitUrl(track.src), sourceUrl)
    .then((url) => fetch(url, containerApiFetchInit(sourceUrl)))
    .catch(() => {})
}

async function fetchContainerStreams(
  sourceUrl: string,
): Promise<ContainerStreamsPayload | null> {
  if ((!useDevStreamProxy() && !useNativeStreamProxy()) || !isContainerUrl(sourceUrl)) {
    log.log("[xt:container-tracks] skip probe", {
      devProxy: useDevStreamProxy(),
      nativeProxy: useNativeStreamProxy(),
      container: isContainerUrl(sourceUrl),
    })
    return null
  }
  const controller =
    typeof AbortController !== "undefined" ? new AbortController() : null
  const timer = controller
    ? setTimeout(() => controller.abort(), STREAM_PROBE_MS)
    : null
  try {
    log.log("[xt:container-tracks] probing", redactUrl(sourceUrl).slice(0, 120))
    const response = await fetch(
      await containerApiUrl(
        `${VOD_STREAMS_PATH}?url=${encodeURIComponent(sourceUrl)}`,
        sourceUrl,
      ),
      containerApiFetchInit(sourceUrl, controller?.signal),
    )
    if (!response.ok) {
      log.warn("[xt:container-tracks] probe HTTP", response.status)
      return null
    }
    const payload = (await response.json()) as ContainerStreamsPayload
    if (payload.error) {
      log.warn("[xt:container-tracks] probe error", payload.error)
    }
    log.log("[xt:container-tracks] probe result", {
      audio: payload.audio?.length ?? 0,
      subtitles: payload.subtitles?.length ?? 0,
      audioSample: (payload.audio || []).slice(0, 4),
      subtitleSample: (payload.subtitles || []).slice(0, 4).map((s) => ({
        lang: s.language,
        label: s.label,
      })),
    })
    return payload
  } catch (error) {
    log.warn("[xt:container-tracks] probe failed", error)
    return null
  } finally {
    if (timer) clearTimeout(timer)
  }
}

export async function countContainerAudioTracks(sourceUrl: string): Promise<number> {
  const payload = await fetchContainerStreams(sourceUrl)
  return payload?.audio?.length ?? 0
}

function waitForContainerVideoReady(
  video: HTMLVideoElement,
  timeoutMs = 20_000,
): Promise<void> {
  if (video.readyState >= 2) return Promise.resolve()
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      trackSettingsDebug("container.video.ready.timeout", {
        readyState: video.readyState,
      })
      resolve()
    }, timeoutMs)
    const done = () => {
      clearTimeout(timer)
      resolve()
    }
    video.addEventListener("canplay", done, { once: true })
    video.addEventListener("loadeddata", done, { once: true })
  })
}

function isBenignVideoSwapError(video: HTMLVideoElement): boolean {
  const code = video.error?.code
  // 1 = MEDIA_ERR_ABORTED when the previous src load is cancelled by a new src
  return code === 1
}

function wireAudioSwitchReady(
  art: any,
  video: HTMLVideoElement,
  gen: number,
  restore: () => void,
  onVideoError?: () => void,
): () => void {
  const onReady = () => {
    if (isAudioSwitchStale(art, gen)) return
    restore()
  }
  const onError = () => {
    onVideoError?.()
  }
  if (typeof art.once === "function") {
    art.once("video:canplay", onReady)
    if (onVideoError) art.once("video:error", onError)
  } else {
    video.addEventListener("canplay", onReady, { once: true })
    if (onVideoError) {
      video.addEventListener("error", onError, { once: true })
    }
  }
  return () => {
    try {
      art.off?.("video:canplay", onReady)
      art.off?.("video:error", onError)
    } catch {}
    video.removeEventListener("canplay", onReady)
    video.removeEventListener("error", onError)
  }
}

function scheduleSubtitleTrackRebindAfterSourceChange(
  art: any,
  video: HTMLVideoElement,
): void {
  const rebind = () => {
    if (art._xtSubtitleApplyInFlight) return
    const last = art._xtLastSubtitleTrack as ContainerSubtitleTrack | undefined
    if (!last) return
    trackSettingsDebug("container.subtitle.rebind", {
      lang: last.language,
      index: last.index,
    })
    void reapplySubtitleFromStoredVtt(art, video).then((fromVtt) => {
      if (fromVtt > 0) return
      const blob = art._xtSubtitleBlobUrl as string | undefined
      if (!blob) return
      void applySubtitleTrackUrl(
        art,
        video,
        blob,
        last.label || last.language || "Subtitle",
        last.language || "",
      ).catch((error) => {
        log.warn("[xt:container-tracks] subtitle rebind failed", error)
      })
    })
  }
  art.once("video:loadedmetadata", rebind)
  art.once("video:canplay", rebind)
}

async function switchContainerAudio(
  art: any,
  video: HTMLVideoElement,
  sourceUrl: string,
  audioIndex: number,
): Promise<void> {
  art._xtAudioSwitchGen = (art._xtAudioSwitchGen ?? 0) + 1
  const gen = art._xtAudioSwitchGen
  abortAudioSwitch(art)
  const abort = new AbortController()
  art._xtAudioSwitchAbort = abort

  const previousIndex =
    typeof art._xtContainerAudioIndex === "number" ? art._xtContainerAudioIndex : 0

  const baseUrl =
    (typeof art._xtContainerSourceUrl === "string" && art._xtContainerSourceUrl) ||
    (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
    sourceUrl
  const resumeAt =
    Number.isFinite(art.currentTime) && art.currentTime > 0
      ? art.currentTime
      : Number.isFinite(video.currentTime)
        ? video.currentTime
        : 0
  const switchingMsg =
    t("player.track.audioSwitching") || "Switching audio track…"
  const remuxPrepMsg =
    t("player.track.audioRemuxPreparing") ||
    "Preparing alternate audio (first time may take a few minutes)…"
  const failMsg =
    t("player.track.audioSwitchFailed") || "Could not switch audio track"

  let directUrl =
    typeof art._xtContainerDirectPlayUrl === "string"
      ? art._xtContainerDirectPlayUrl
      : ""
  if (directUrl.includes(VOD_REMUX_PATH)) {
    directUrl = resolveEmbeddedStreamUrl(
      art._xtContainerSourceUrl || sourceUrl,
    )
    art._xtContainerDirectPlayUrl = directUrl
  }
  if (useNativeStreamProxy() && (!directUrl || !isTauriTranscodeUrl(directUrl))) {
    const transcode = await resolveTauriTranscodeUrl(baseUrl, 0, resumeAt)
    if (transcode) {
      directUrl = transcode
      art._xtContainerDirectPlayUrl = transcode
    }
  }
  const useDirect = audioIndex === 0 && Boolean(directUrl)

  markContainerPlaybackGuard(art, useDirect ? 8_000 : REMUX_WAIT_MS + 15_000)

  trackSettingsDebug("container.audio.switch.start", {
    index: audioIndex,
    gen,
    resumeAt,
    mode: useDirect ? "direct" : "remux",
    baseUrl: redactUrl(baseUrl).slice(0, 80),
    directUrl: redactUrl(directUrl).slice(0, 80),
    videoSrcBefore: redactUrl(video.src || "").slice(0, 80),
    readyState: video.readyState,
  })

  try {
    art.notice.show = switchingMsg
  } catch {}

  art.hls = null
  art._xtContainerAudioIndex = audioIndex

  let restored = false
  const detachReadyListeners = () => {
    if (typeof art._xtAudioSwitchCleanup === "function") {
      art._xtAudioSwitchCleanup()
      art._xtAudioSwitchCleanup = null
    }
  }
  const restore = () => {
    if (isAudioSwitchStale(art, gen) || restored) return
    restored = true
    detachReadyListeners()
    clearContainerPlaybackGuard(art)
    try {
      art.notice.show = ""
    } catch {}
    if (resumeAt > 0.5) {
      const targetTime =
        art?._xtVirtualTimelineInstalled
          ? 0
          : Math.max(0, resumeAt - playbackOffset(art))
      try {
        video.currentTime = targetTime
      } catch {}
      try {
        art.currentTime = targetTime
      } catch {}
    }
    void art.play?.()?.catch(() => {})
    trackSettingsDebug("container.audio.switch.ready", {
      index: audioIndex,
      gen,
      currentTime: video.currentTime,
      videoSrc: redactUrl(video.src || "").slice(0, 100),
    })
  }

  const showFail = (rollback = false) => {
    if (isAudioSwitchStale(art, gen)) return
    detachReadyListeners()
    if (rollback) {
      art._xtContainerAudioIndex = previousIndex
    }
    clearContainerPlaybackGuard(art)
    try {
      art.notice.show = failMsg
    } catch {}
    setTimeout(() => {
      if (!isAudioSwitchStale(art, gen)) {
        try {
          art.notice.show = ""
        } catch {}
      }
    }, 3500)
  }

  const onVideoError = () => {
    if (isAudioSwitchStale(art, gen) || isBenignVideoSwapError(video)) return
    if (!useDirect && directUrl && isRemuxDecodeError(video)) {
      trackSettingsDebug("container.audio.remux.rollback", {
        index: audioIndex,
        gen,
        code: video.error?.code,
        resumeAt,
      })
      art._xtContainerAudioIndex = 0
      markContainerPlaybackGuard(art, 8_000)
      setArtplayerNativeSource(art, video, directUrl)
      wireAudioSwitchReady(art, video, gen, restore)
      showFail()
      return
    }
    showFail(true)
  }

  const detachReady = wireAudioSwitchReady(art, video, gen, restore, onVideoError)
  art._xtAudioSwitchCleanup = detachReady

  try {
    if (useDirect) {
      if (isAudioSwitchStale(art, gen)) return
      if (isTauriTranscodeUrl(directUrl)) {
        setArtplayerTsSource(art, video, directUrl, resumeAt)
      } else {
        art._xtPlaybackOffsetSeconds = 0
        setArtplayerNativeSource(art, video, directUrl)
      }
      trackSettingsDebug("container.audio.switch.direct", {
        index: audioIndex,
        gen,
        videoSrc: redactUrl(video.src).slice(0, 100),
      })
      scheduleSubtitleTrackRebindAfterSourceChange(art, video)
      if (video.readyState >= 3) restore()
      return
    }

    if (useNativeStreamProxy()) {
      const transcodeUrl = await resolveTauriTranscodeUrl(baseUrl, audioIndex, resumeAt)
      if (!transcodeUrl) throw new Error("transcode unavailable")
      try {
        art.notice.show = switchingMsg
      } catch {}
      if (isAudioSwitchStale(art, gen)) return
      art._xtPlaybackOffsetSeconds = 0
      setArtplayerTsSource(art, video, transcodeUrl, resumeAt)
      trackSettingsDebug("container.audio.switch.transcode", {
        index: audioIndex,
        gen,
        videoSrc: redactUrl(video.src).slice(0, 100),
      })
      scheduleSubtitleTrackRebindAfterSourceChange(art, video)
      if (resumeAt > 0.5) {
        art.once?.("video:loadedmetadata", () => {
          try { art.currentTime = 0 } catch {}
        })
      }
      if (video.readyState >= 3) restore()
      return
    }

    const remuxBase = absoluteAssetUrl(wrapVodRemuxUrl(baseUrl, audioIndex))
    const cached = await probeRemuxCacheReady(remuxBase, baseUrl, abort.signal)
    if (isAudioSwitchStale(art, gen)) return

    if (!cached) {
      try {
        art.notice.show = remuxPrepMsg
      } catch {}
    }
    trackSettingsDebug("container.audio.remux.wait", {
      index: audioIndex,
      gen,
      cached,
    })
    const waitStarted = Date.now()
    await waitForVodRemuxComplete(remuxBase, baseUrl, abort.signal)
    trackSettingsDebug("container.audio.remux.wait.done", {
      index: audioIndex,
      gen,
      ms: Date.now() - waitStarted,
    })
    if (isAudioSwitchStale(art, gen)) return

    const playUrl = `${remuxBase}&_=${Date.now()}`
    art._xtPlaybackOffsetSeconds = 0
    setArtplayerNativeSource(art, video, playUrl)
    trackSettingsDebug("container.audio.switch.remux", {
      index: audioIndex,
      gen,
      videoSrc: redactUrl(video.src).slice(0, 100),
    })
    scheduleSubtitleTrackRebindAfterSourceChange(art, video)
    if (video.readyState >= 3) restore()
  } catch (error) {
    if (isAudioSwitchStale(art, gen)) return
    if ((error as Error)?.name === "AbortError") return
    log.warn("[xt:container-tracks] audio switch failed", error)
    trackSettingsDebug("container.audio.switch.error", {
      index: audioIndex,
      gen,
      error: String((error as Error)?.message || error),
    })
    art._xtContainerAudioIndex = previousIndex
    showFail()
  } finally {
    if (gen === art._xtAudioSwitchGen) {
      art._xtAudioSwitchAbort = null
    }
  }
}

function isSubtitleApplyStale(art: any, gen: number): boolean {
  return gen !== art._xtSubtitleApplyGen
}

async function applyContainerSubtitle(
  art: any,
  track: ContainerSubtitleTrack | null,
): Promise<void> {
  const video = art?.video as HTMLVideoElement | undefined
  if (!video) return

  art._xtSubtitleApplyGen = (art._xtSubtitleApplyGen ?? 0) + 1
  const gen = art._xtSubtitleApplyGen
  abortSubtitleFetch(art)

  if (!track?.src) {
    revokeSubtitleBlob(art)
    clearArtplayerSubtitleOverlay(art, video)
    art._xtLastSubtitleTrack = undefined
    art._xtSubtitleApplyInFlight = false
    clearContainerPlaybackGuard(art)
    try {
      art.notice.show = ""
    } catch {}
    log.log("[xt:container-tracks] subtitles off")
    return
  }

  const probeUrl =
    (typeof art._xtContainerSourceUrl === "string" && art._xtContainerSourceUrl) ||
    ""
  const loadingMsg =
    t("player.subtitle.loading") ||
    "Loading subtitles (first time may take a few minutes)…"
  const { resumeAt, wasPlaying } = capturePlaybackState(video, art)
  markContainerPlaybackGuard(art)
  art._xtSubtitleApplyInFlight = true
  const stopLoadingNotice = startSubtitleLoadingNotice(art, loadingMsg, gen)

  try {
    const abort = new AbortController()
    art._xtSubtitleFetchAbort = abort

    const name = track.label || track.language || "Subtitle"
    const cachedAlready = await probeSubtitleCacheReady(
      track.src,
      probeUrl,
      abort.signal,
    )

    trackSettingsDebug("container.subtitle.start", {
      index: track.index,
      lang: track.language,
      label: track.label,
      resumeAt,
      gen,
      mode: cachedAlready ? "cache-hit" : "cache-extract",
      videoSrc: redactUrl(video.src).slice(0, 80),
    })
    const started = Date.now()
    revokeSubtitleBlob(art)
    art._xtLastSubtitleTrack = track

    await waitForSubtitleExtract(track.src, probeUrl, abort.signal)
    if (isSubtitleApplyStale(art, gen)) return

    const { blobUrl, vttText } = await fetchSubtitleVttBlob(
      track.src,
      probeUrl,
      abort.signal,
    )
    if (isSubtitleApplyStale(art, gen)) {
      try {
        URL.revokeObjectURL(blobUrl)
      } catch {}
      return
    }
    art._xtSubtitleVttFull = vttText
    art._xtSubtitleBlobUrl = blobUrl

    const $track = replaceXtSubtitleTrackElement(
      art,
      video,
      name,
      track.language || "",
    )
    const textTrack = await loadXtSubtitleFromBlob(
      art,
      video,
      $track,
      blobUrl,
      name,
      track.language || "",
    )
    const cueCount = textTrack.cues?.length ?? 0
    if (cueCount === 0) {
      throw new Error("subtitle track has no cues")
    }

    if (!finalizeXtSubtitleDisplay(art, video, $track, gen)) return

    if (isSubtitleApplyStale(art, gen)) return
    restorePlaybackState(art, video, resumeAt, wasPlaying)
    const activeCount = textTrack.activeCues?.length ?? 0
    trackSettingsDebug("container.subtitle.active", {
      lang: track.language,
      label: track.label,
      ms: Date.now() - started,
      gen,
      cues: cueCount,
      activeCues: activeCount,
      currentTime: video.currentTime,
    })
    const list = art._xtContainerSubtitleTracks as ContainerSubtitleTrack[] | undefined
    const idx =
      typeof art._xtSubtitleActiveListIndex === "number"
        ? art._xtSubtitleActiveListIndex
        : list?.findIndex((row) => row.index === track.index) ?? -1
    if (list && idx >= 0) {
      refreshContainerSubtitleMenu(art, list, idx)
    }
  } catch (error) {
    if (isSubtitleApplyStale(art, gen)) return
    if ((error as Error)?.name === "AbortError") return
    log.warn("[xt:container-tracks] subtitle switch failed", error)
    trackSettingsDebug("container.subtitle.error", {
      index: track.index,
      error: String((error as Error)?.message || error),
      gen,
    })
    restorePlaybackState(art, video, resumeAt, wasPlaying)
    art.notice.show =
      t("player.subtitle.extractFailed") ||
      "Could not load this subtitle track"
    setTimeout(() => {
      if (!isSubtitleApplyStale(art, gen)) {
        art.notice.show = ""
      }
    }, 3500)
  } finally {
    stopLoadingNotice()
    if (gen === art._xtSubtitleApplyGen) {
      clearContainerPlaybackGuard(art)
      art._xtSubtitleApplyInFlight = false
      art._xtSubtitleFetchAbort = null
      try {
        art.notice.show = ""
      } catch {}
    }
  }
}

function refreshContainerAudioMenu(
  art: any,
  video: HTMLVideoElement,
  sourceUrl: string,
  audioTracks: ContainerAudioTrack[],
  activeIndex: number,
): void {
  removeArtplayerSetting(art, SETTING_AUDIO)

  const activeTrack =
    audioTracks.find((track) => track.index === activeIndex) || audioTracks[0]
  const activePos = Math.max(
    0,
    audioTracks.findIndex((track) => track.index === activeIndex),
  )

  const selector: ArtplayerSelectorRow[] = audioTracks.map((track, listPos) => ({
    html: formatContainerAudioLabel(track, listPos),
    default: track.index === activeIndex,
    _xtKind: "container-audio",
    _xtPayload: track,
  }))

  art.setting.add({
    name: SETTING_AUDIO,
    html: audioSettingHtml(activeTrack, activePos),
    width: 280,
    selector,
    onSelect(item: ArtplayerSelectorRow) {
      const track = item?._xtPayload as ContainerAudioTrack | undefined
      trackSettingsDebug("container.audio.menu.select", {
        html: item?.html,
        trackIndex: track?.index,
        activeBefore: art._xtContainerAudioIndex,
      })
      if (!track || item._xtKind !== "container-audio") {
        trackSettingsDebug("container.audio.menu.skip", { kind: item?._xtKind })
        return audioSettingHtml(activeTrack, activePos)
      }
      const listPos = audioTracks.findIndex((row) => row.index === track.index)
      if (track.index === art._xtContainerAudioIndex) {
        return audioSettingHtml(track, listPos >= 0 ? listPos : 0)
      }
      saveTrackPreference("audio", track)
      art._xtContainerAudioIndex = track.index
      if (track.index > 0) prefetchContainerRemux(sourceUrl, track.index)
      void switchContainerAudio(art, video, sourceUrl, track.index).finally(() => {
        if (art._xtContainerAudioIndex === track.index) {
          refreshContainerAudioMenu(art, video, sourceUrl, audioTracks, track.index)
        }
      })
      return audioSettingHtml(track, listPos >= 0 ? listPos : 0)
    },
  })
  trackSettingsDebug("container.audio.menu.wired", {
    tracks: audioTracks.length,
    activeIndex,
  })
}

function refreshContainerSubtitleMenu(
  art: any,
  subtitleTracks: ContainerSubtitleTrack[],
  activeListIndex: number,
): void {
  removeArtplayerSetting(art, SETTING_SUBTITLE)
  art._xtContainerSubtitleTracks = subtitleTracks
  art._xtSubtitleActiveListIndex = activeListIndex

  const activeTrack =
    activeListIndex >= 0 ? subtitleTracks[activeListIndex] : null

  const selector: ArtplayerSelectorRow[] = [
    {
      html: t("player.subtitle.off") || "Off",
      default: activeListIndex < 0,
      _xtKind: "container-subtitle-off",
    },
    ...subtitleTracks.map((track, listIndex) => ({
      html: formatContainerSubtitleLabel(
        {
          index: track.index,
          language: track.language,
          label: track.label,
          codec: track.codec,
        },
        listIndex,
      ),
      default: listIndex === activeListIndex,
      _xtKind: "container-subtitle",
      _xtPayload: { track, listIndex },
    })),
  ]

  art.setting.add({
    name: SETTING_SUBTITLE,
    html: subtitleSettingHtml(activeTrack, activeListIndex),
    width: 280,
    selector,
    onSelect(item: ArtplayerSelectorRow) {
      const tracks =
        (art._xtContainerSubtitleTracks as ContainerSubtitleTrack[] | undefined) ||
        subtitleTracks
      const currentIndex =
        typeof art._xtSubtitleActiveListIndex === "number"
          ? art._xtSubtitleActiveListIndex
          : activeListIndex
      const currentTrack =
        currentIndex >= 0 ? tracks[currentIndex] : null

      trackSettingsDebug("container.subtitle.menu.select", {
        html: item?.html,
        kind: item?._xtKind,
        inFlight: Boolean(art._xtSubtitleApplyInFlight),
      })
      if (item?._xtKind === "container-subtitle-off") {
        clearTrackPreference("subtitle")
        refreshContainerSubtitleMenu(art, tracks, -1)
        void applyContainerSubtitle(art, null)
        return subtitleSettingHtml(null, -1)
      }
      const payload = item?._xtPayload as
        | { track: ContainerSubtitleTrack; listIndex: number }
        | undefined
      if (!payload?.track || item._xtKind !== "container-subtitle") {
        return subtitleSettingHtml(currentTrack, currentIndex)
      }
      saveTrackPreference("subtitle", payload.track)
      art._xtSubtitleActiveListIndex = payload.listIndex
      const probeUrl =
        (typeof art._xtContainerSourceUrl === "string" &&
          art._xtContainerSourceUrl) ||
        ""
      if (probeUrl) prefetchContainerSubtitle(probeUrl, payload.track)
      refreshContainerSubtitleMenu(art, tracks, payload.listIndex)
      void applyContainerSubtitle(art, payload.track)
      return subtitleSettingHtml(payload.track, payload.listIndex)
    },
  })
  trackSettingsDebug("container.subtitle.menu.wired", {
    tracks: subtitleTracks.length,
  })
}

async function tryRicherContainerSibling(
  art: any,
  sourceUrl: string,
  payload: ContainerStreamsPayload | null,
): Promise<{ sourceUrl: string; payload: ContainerStreamsPayload | null }> {
  const audioCount = payload?.audio?.length ?? 0
  const subCount = payload?.subtitles?.length ?? 0
  if (audioCount > 1 || subCount > 0) {
    return { sourceUrl, payload }
  }
  const { toMkvSiblingUrl } = await import("@/scripts/lib/embedded-vod-playback.js")
  const mkvUrl = toMkvSiblingUrl(sourceUrl)
  if (!mkvUrl) return { sourceUrl, payload }

  log.log("[xt:container-tracks] mp4 has few tracks; probing MKV sibling", {
    mp4: redactUrl(sourceUrl).slice(0, 100),
    mkv: redactUrl(mkvUrl).slice(0, 100),
  })
  const mkvPayload = await fetchContainerStreams(mkvUrl)
  if (!mkvPayload) return { sourceUrl, payload }

  const mkvAudio = mkvPayload.audio?.length ?? 0
  const mkvSub = mkvPayload.subtitles?.length ?? 0
  if (mkvAudio <= audioCount && mkvSub <= subCount) {
    return { sourceUrl, payload }
  }

  try {
    const resumeAt =
      art?.video ? absolutePlaybackTime(art, art.video) : playbackOffset(art)
    let resolved = await resolveNativeStreamProxyUrl(resolveEmbeddedStreamUrl(mkvUrl))
    let bridge = "native"
    if (useNativeStreamProxy()) {
      const hlsBase = await containerApiUrl(wrapVodHlsUrl(mkvUrl, 0), mkvUrl)
      try {
        art.notice.show =
          t("player.track.audioRemuxPreparing") ||
          "Preparing alternate audio (first time may take a few minutes)…"
      } catch {}
      await waitForGeneratedVodReady(hlsBase, mkvUrl)
      resolved = `${hlsBase}&_=${Date.now()}`
      bridge = "tauri-hls"
    }
    art._xtContainerSourceUrl = mkvUrl
    art._xtContainerDirectPlayUrl = resolved
    art._xtTranscodeSrcUrl = undefined
    art.type = useNativeStreamProxy() ? "m3u8" : "xt-native"
    art._xtPlaybackOffsetSeconds = 0
    art.url = resolved
    if (art.video && resumeAt > 0.5) {
      art.once?.("video:loadedmetadata", () => {
        try { art.currentTime = resumeAt } catch {}
      })
    }
    log.log("[xt:container-tracks] using MKV for multi-track playback", {
      audio: mkvAudio,
      subtitles: mkvSub,
      bridge,
    })
  } catch (error) {
    log.warn("[xt:container-tracks] MKV switch failed; keeping MP4", error)
    return { sourceUrl, payload }
  }

  return { sourceUrl: mkvUrl, payload: mkvPayload }
}

function refreshContainerAudioSingleOnly(
  art: any,
  track: ContainerAudioTrack,
): void {
  removeArtplayerSetting(art, SETTING_AUDIO)
  const label = formatContainerAudioLabel(track, 0)
  art.setting.add({
    name: SETTING_AUDIO,
    html: settingTitle(t("player.menu.audio") || "Audio", label),
    width: 280,
    selector: [
      {
        html: `${label} · ${t("player.track.audioEmbeddedOnly") || "Only one audio track in this file"}`,
        default: true,
        onSelect() {},
      },
    ],
  })
}

function refreshContainerSubtitleMenuEmpty(art: any): void {
  removeArtplayerSetting(art, SETTING_SUBTITLE)
  art.setting.add({
    name: SETTING_SUBTITLE,
    html: settingTitle(
      t("player.menu.subtitle") || "Subtitles",
      t("player.subtitle.off") || "Off",
    ),
    width: 280,
    selector: [
      {
        html: t("player.subtitle.unavailable") || "Not available on this stream",
        default: true,
        onSelect() {},
      },
    ],
  })
}

/**
 * Probe embedded streams and wire ArtPlayer track menus (dev proxy + ffmpeg only).
 * Non-blocking: call after `art.url` is set so playback can start immediately.
 */
export async function attachContainerTracksForArtplayer(
  art: any,
  sourceUrl: string,
  attempt = 0,
): Promise<void> {
  if (
    !art?.video ||
    (!useDevStreamProxy() && !useNativeStreamProxy()) ||
    !isContainerUrl(sourceUrl)
  ) {
    art._xtPendingContainerTracks = false
    return
  }

  const probeKey = vodAssetPathKey(sourceUrl)
  if (art._xtContainerTracks && art._xtContainerProbeKey === probeKey) {
    art._xtPendingContainerTracks = false
    trackSettingsDebug("container.attach.skip", { reason: "already-wired", probeKey })
    return
  }

  const inflight = art._xtContainerAttachInflight as Promise<boolean> | undefined
  if (inflight) {
    await inflight
    return
  }

  const task = attachContainerTracksForArtplayerInner(art, sourceUrl, probeKey)
  art._xtContainerAttachInflight = task
  let attached = false
  try {
    attached = await task
  } finally {
    if (art._xtContainerAttachInflight === task) {
      art._xtContainerAttachInflight = undefined
    }
  }
  if (!attached && attempt < TRACK_ATTACH_RETRY_MS.length) {
    const delay = TRACK_ATTACH_RETRY_MS[attempt] ?? 0
    trackSettingsDebug("container.attach.retry", { attempt: attempt + 1, delay, probeKey })
    setTimeout(() => {
      void attachContainerTracksForArtplayer(art, sourceUrl, attempt + 1)
    }, delay)
  }
}

async function attachContainerTracksForArtplayerInner(
  art: any,
  sourceUrl: string,
  probeKey: string,
): Promise<boolean> {
  art._xtPendingContainerTracks = true
  removeNativeTrackSettings(art)
  let probeUrl = sourceUrl
  let payload = await fetchContainerStreams(probeUrl)
  const richer = await tryRicherContainerSibling(art, probeUrl, payload)
  probeUrl = richer.sourceUrl
  payload = richer.payload
  art._xtPendingContainerTracks = false

  if (!payload) return false

  const audioTracks = payload.audio || []
  const subtitleTracks = payload.subtitles || []
  if (audioTracks.length === 0 && subtitleTracks.length === 0) {
    log.warn("[xt:container-tracks] no embedded tracks found in file")
    refreshContainerSubtitleMenuEmpty(art)
    return false
  }

  art._xtContainerTracks = true
  art._xtContainerProbeKey = vodAssetPathKey(probeUrl)
  art._xtContainerSourceUrl = probeUrl
  art._xtContainerDirectPlayUrl =
    (useNativeStreamProxy()
      ? await resolveTauriTranscodeUrl(probeUrl, 0, 0)
      : null) || resolveEmbeddedStreamUrl(probeUrl)
  removeNativeTrackSettings(art)

  const video = art.video as HTMLVideoElement

  const activeSubtitleIndex = -1

  if (audioTracks.length > 1) {
    const pref = findPreferredTrackIndex("audio", audioTracks)
    const active = pref >= 0 ? audioTracks[pref] : audioTracks[0]
    const activeIndex = active?.index ?? 0
    if (activeIndex > 0) {
      const applyPreferred = () => {
        trackSettingsDebug("container.audio.pref.apply", {
          activeIndex,
          readyState: video.readyState,
        })
        void switchContainerAudio(art, video, probeUrl, activeIndex)
      }
      if (video.readyState >= 2) {
        applyPreferred()
      } else {
        trackSettingsDebug("container.audio.pref.defer", { activeIndex })
        video.addEventListener("canplay", applyPreferred, { once: true })
      }
    }
    refreshContainerAudioMenu(art, video, probeUrl, audioTracks, activeIndex)
    if (activeIndex > 0) prefetchContainerRemux(probeUrl, activeIndex)
  } else if (audioTracks.length === 1) {
    refreshContainerAudioSingleOnly(art, audioTracks[0]!)
  }

  if (subtitleTracks.length > 0) {
    refreshContainerSubtitleMenu(art, subtitleTracks, activeSubtitleIndex)
    const prefSub = findPreferredTrackIndex("subtitle", subtitleTracks)
    const warm =
      prefSub >= 0 ? subtitleTracks[prefSub]! : subtitleTracks[0]
    if (warm) prefetchContainerSubtitle(probeUrl, warm)
  } else {
    refreshContainerSubtitleMenuEmpty(art)
  }

  trackSettingsDebug("container.menus.wired", {
    source: redactUrl(probeUrl).slice(0, 100),
    audio: audioTracks.length,
    subtitles: subtitleTracks.length,
    directPlayUrl: redactUrl(art._xtContainerDirectPlayUrl || "").slice(0, 80),
  })

  if (art.video?.paused && art._xtPlayAfterSourceLoad) {
    void art.play?.()?.catch(() => {})
  }
  return true
}
