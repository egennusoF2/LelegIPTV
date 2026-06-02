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
  type ArtplayerSelectorRow,
} from "@/scripts/lib/artplayer-track-settings.js"

const VOD_STREAMS_PATH = "/__vod_streams"
const VOD_REMUX_PATH = "/__vod_remux"
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

const STREAM_PROBE_MS = 12_000

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

const EMPTY_VTT =
  "data:text/vtt;charset=utf-8,WEBVTT%0A%0A"

function ensureArtplayerSubtitleTrack(video: HTMLVideoElement): void {
  if (video.textTracks?.length) return
  const track = document.createElement("track")
  track.kind = "metadata"
  track.label = "xt"
  track.src = EMPTY_VTT
  video.appendChild(track)
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

async function fetchSubtitleBlobUrl(
  subtitlePath: string,
  sourceUrl: string,
): Promise<string> {
  const url = absoluteAssetUrl(subtitlePath)
  const headers = resolveMediaHeaders(sourceUrl)
  const response = await fetch(url, {
    headers: devProxyFetchHeaders(headers),
  })
  if (!response.ok) {
    throw new Error(`subtitle HTTP ${response.status}`)
  }
  const blob = await response.blob()
  if (!blob.size) {
    throw new Error("subtitle empty")
  }
  return URL.createObjectURL(blob)
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

/** Warm subtitle cache in background (does not block playback or menus). */
function prefetchContainerSubtitle(
  sourceUrl: string,
  track: ContainerSubtitleTrack,
): void {
  if (!track?.src) return
  const url = absoluteAssetUrl(track.src)
  const headers = resolveMediaHeaders(sourceUrl)
  void fetch(url, { headers: devProxyFetchHeaders(headers) }).catch(() => {})
}

async function fetchContainerStreams(
  sourceUrl: string,
): Promise<ContainerStreamsPayload | null> {
  if (!useDevStreamProxy() || !isContainerUrl(sourceUrl)) {
    log.log("[xt:container-tracks] skip probe", {
      devProxy: useDevStreamProxy(),
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
    const headers = resolveMediaHeaders(sourceUrl)
    const response = await fetch(
      `${VOD_STREAMS_PATH}?url=${encodeURIComponent(sourceUrl)}`,
      {
        headers: devProxyFetchHeaders(headers),
        signal: controller?.signal,
      },
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

async function switchContainerAudio(
  art: any,
  video: HTMLVideoElement,
  sourceUrl: string,
  audioIndex: number,
): Promise<void> {
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
  const failMsg =
    t("player.track.audioSwitchFailed") || "Could not switch audio track"

  const directUrl =
    typeof art._xtContainerDirectPlayUrl === "string"
      ? art._xtContainerDirectPlayUrl
      : ""
  const useDirect =
    audioIndex === 0 &&
    directUrl &&
    !directUrl.includes(VOD_REMUX_PATH)

  trackSettingsDebug("container.audio.switch.start", {
    index: audioIndex,
    resumeAt,
    mode: useDirect ? "direct" : "remux",
    baseUrl: redactUrl(baseUrl).slice(0, 80),
    directUrl: redactUrl(directUrl).slice(0, 80),
    videoSrcBefore: redactUrl(video.src || "").slice(0, 80),
  })

  try {
    art.notice.show = switchingMsg
  } catch {}

  art.hls = null
  art._xtContainerAudioIndex = audioIndex

  let restored = false
  const restore = () => {
    if (restored) return
    restored = true
    try {
      art.notice.show = ""
    } catch {}
    if (resumeAt > 1) {
      try {
        art.currentTime = resumeAt
      } catch {}
    }
    void art.play?.()?.catch(() => {})
  }
  const onFail = () => {
    try {
      art.notice.show = failMsg
    } catch {}
    setTimeout(() => {
      try {
        art.notice.show = ""
      } catch {}
    }, 3500)
  }

  art.once("video:canplay", restore)
  art.once("video:loadedmetadata", restore)
  video.addEventListener("error", onFail, { once: true })

  try {
    if (useDirect) {
      art.type = "xt-native"
      art.url = directUrl
      trackSettingsDebug("container.audio.switch.direct", {
        index: audioIndex,
        videoSrc: redactUrl(video.src).slice(0, 100),
      })
      return
    }

    const remuxBase = absoluteAssetUrl(wrapVodRemuxUrl(baseUrl, audioIndex))
    const headers = resolveMediaHeaders(baseUrl)
    trackSettingsDebug("container.audio.remux.prime", {
      index: audioIndex,
      remux: redactUrl(remuxBase).slice(0, 100),
    })
    const prime = await fetch(remuxBase, {
      headers: {
        ...devProxyFetchHeaders(headers),
        Range: "bytes=0-131071",
      },
    })
    trackSettingsDebug("container.audio.remux.prime.done", {
      index: audioIndex,
      status: prime.status,
      contentType: prime.headers.get("content-type"),
      contentLength: prime.headers.get("content-length"),
    })
    if (!prime.ok) {
      throw new Error(`remux prime HTTP ${prime.status}`)
    }
    await prime.arrayBuffer().catch(() => new ArrayBuffer(0))

    art.type = "xt-native"
    art.url = `${remuxBase}&_=${Date.now()}`
    trackSettingsDebug("container.audio.switch.remux", {
      index: audioIndex,
      videoSrc: redactUrl(video.src).slice(0, 100),
    })
  } catch (error) {
    log.warn("[xt:container-tracks] audio switch failed", error)
    trackSettingsDebug("container.audio.switch.error", {
      index: audioIndex,
      error: String((error as Error)?.message || error),
    })
    onFail()
  }
}

async function applyContainerSubtitle(
  art: any,
  track: ContainerSubtitleTrack | null,
): Promise<void> {
  if (!track?.src) {
    revokeSubtitleBlob(art)
    try {
      await art.subtitle.switch("")
    } catch {}
    log.log("[xt:container-tracks] subtitles off")
    return
  }
  const probeUrl =
    (typeof art._xtContainerSourceUrl === "string" && art._xtContainerSourceUrl) ||
    ""
  const loadingMsg =
    t("player.subtitle.loading") || "Preparing subtitles (first time may take a moment)…"
  try {
    art.notice.show = loadingMsg
    trackSettingsDebug("container.subtitle.start", {
      index: track.index,
      lang: track.language,
      label: track.label,
      textTracks: art.video?.textTracks?.length ?? 0,
    })
    const started = Date.now()
    if (art.video) {
      ensureArtplayerSubtitleTrack(art.video as HTMLVideoElement)
    }
    revokeSubtitleBlob(art)
    const blobUrl = await fetchSubtitleBlobUrl(track.src, probeUrl)
    art._xtSubtitleBlobUrl = blobUrl
    await art.subtitle.switch(blobUrl, {
      name: track.label || track.language || "Subtitle",
      type: "vtt",
    })
    trackSettingsDebug("container.subtitle.active", {
      lang: track.language,
      label: track.label,
      ms: Date.now() - started,
      blobUrl: blobUrl.slice(0, 40),
      subtitleUrl: art.subtitle?.url?.slice?.(0, 40),
      activeCues: art.subtitle?.activeCues?.length ?? 0,
    })
  } catch (error) {
    log.warn("[xt:container-tracks] subtitle switch failed", error)
    trackSettingsDebug("container.subtitle.error", {
      index: track.index,
      error: String((error as Error)?.message || error),
    })
    art.notice.show =
      t("player.subtitle.extractFailed") || "Could not load this subtitle track"
    setTimeout(() => {
      art.notice.show = ""
    }, 3500)
    return
  } finally {
    art.notice.show = ""
  }
}

function refreshContainerAudioMenu(
  art: any,
  video: HTMLVideoElement,
  sourceUrl: string,
  audioTracks: ContainerAudioTrack[],
  activeIndex: number,
): void {
  try {
    art.setting.remove(SETTING_AUDIO)
  } catch {}

  const activeTrack =
    audioTracks.find((track) => track.index === activeIndex) || audioTracks[0]
  const activePos = Math.max(
    0,
    audioTracks.findIndex((track) => track.index === activeIndex),
  )
  const activeLabel = activeTrack
    ? formatContainerAudioLabel(activeTrack, activePos)
    : ""

  const selector: ArtplayerSelectorRow[] = audioTracks.map((track, listPos) => ({
    html: formatContainerAudioLabel(track, listPos),
    default: track.index === activeIndex,
    _xtKind: "container-audio",
    _xtPayload: track,
  }))

  art.setting.add({
    name: SETTING_AUDIO,
    html: settingTitle(t("player.menu.audio") || "Audio", activeLabel),
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
        return item?.html || ""
      }
      saveTrackPreference("audio", track)
      void switchContainerAudio(art, video, sourceUrl, track.index).then(() => {
        refreshContainerAudioMenu(art, video, sourceUrl, audioTracks, track.index)
      })
      return item.html || ""
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
  try {
    art.setting.remove(SETTING_SUBTITLE)
  } catch {}

  const activeTrack =
    activeListIndex >= 0 ? subtitleTracks[activeListIndex] : null
  const activeLabel = activeTrack
    ? formatContainerSubtitleLabel(activeTrack, activeListIndex)
    : t("player.subtitle.off") || "Off"

  const selector: ArtplayerSelectorRow[] = [
    {
      html: t("player.subtitle.off") || "Off",
      default: activeListIndex < 0,
      _xtKind: "container-subtitle-off",
    },
    ...subtitleTracks.map((track, listIndex) => ({
      html: formatContainerSubtitleLabel(track, listIndex),
      default: listIndex === activeListIndex,
      _xtKind: "container-subtitle",
      _xtPayload: { track, listIndex },
    })),
  ]

  art.setting.add({
    name: SETTING_SUBTITLE,
    html: settingTitle(t("player.menu.subtitle") || "Subtitles", activeLabel),
    width: 280,
    selector,
    onSelect(item: ArtplayerSelectorRow) {
      trackSettingsDebug("container.subtitle.menu.select", {
        html: item?.html,
        kind: item?._xtKind,
      })
      if (item?._xtKind === "container-subtitle-off") {
        clearTrackPreference("subtitle")
        void applyContainerSubtitle(art, null)
        refreshContainerSubtitleMenu(art, subtitleTracks, -1)
        return item.html || ""
      }
      const payload = item?._xtPayload as
        | { track: ContainerSubtitleTrack; listIndex: number }
        | undefined
      if (!payload?.track || item._xtKind !== "container-subtitle") {
        return item?.html || ""
      }
      saveTrackPreference("subtitle", payload.track)
      void applyContainerSubtitle(art, payload.track).then(() => {
        refreshContainerSubtitleMenu(art, subtitleTracks, payload.listIndex)
      })
      return item.html || ""
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
    const resolved = await resolveNativeStreamProxyUrl(resolveEmbeddedStreamUrl(mkvUrl))
    art.type = "xt-native"
    art.url = resolved
    log.log("[xt:container-tracks] using MKV for multi-track playback", {
      audio: mkvAudio,
      subtitles: mkvSub,
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
  try {
    art.setting.remove(SETTING_AUDIO)
  } catch {}
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
  try {
    art.setting.remove(SETTING_SUBTITLE)
  } catch {}
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
): Promise<void> {
  if (!art?.video || art.hls || !useDevStreamProxy() || !isContainerUrl(sourceUrl)) {
    art._xtPendingContainerTracks = false
    return
  }

  art._xtPendingContainerTracks = true
  removeNativeTrackSettings(art)
  let probeUrl = sourceUrl
  let payload = await fetchContainerStreams(probeUrl)
  const richer = await tryRicherContainerSibling(art, probeUrl, payload)
  probeUrl = richer.sourceUrl
  payload = richer.payload
  art._xtPendingContainerTracks = false

  if (!payload) return

  const audioTracks = payload.audio || []
  const subtitleTracks = payload.subtitles || []
  if (audioTracks.length === 0 && subtitleTracks.length === 0) {
    log.warn("[xt:container-tracks] no embedded tracks found in file")
    refreshContainerSubtitleMenuEmpty(art)
    return
  }

  art._xtContainerTracks = true
  art._xtContainerSourceUrl = probeUrl
  if (art.video?.src) {
    art._xtContainerDirectPlayUrl = art.video.src
  } else if (typeof art.url === "string" && art.url) {
    art._xtContainerDirectPlayUrl = art.url
  }
  removeNativeTrackSettings(art)

  const video = art.video as HTMLVideoElement

  const activeSubtitleIndex = -1

  if (audioTracks.length > 1) {
    const pref = findPreferredTrackIndex("audio", audioTracks)
    const active = pref >= 0 ? audioTracks[pref] : audioTracks[0]
    const activeIndex = active?.index ?? 0
    if (activeIndex > 0) {
      void switchContainerAudio(art, video, probeUrl, activeIndex)
    }
    refreshContainerAudioMenu(art, video, probeUrl, audioTracks, activeIndex)
  } else if (audioTracks.length === 1) {
    refreshContainerAudioSingleOnly(art, audioTracks[0]!)
  }

  if (subtitleTracks.length > 0) {
    refreshContainerSubtitleMenu(art, subtitleTracks, activeSubtitleIndex)
    const prefIdx = findPreferredTrackIndex("subtitle", subtitleTracks)
    if (prefIdx >= 0) {
      prefetchContainerSubtitle(probeUrl, subtitleTracks[prefIdx]!)
    }
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
}
