import { log } from "@/scripts/lib/log.js"
import { t } from "@/scripts/lib/i18n.js"
import {
  ensureVideoAudible,
  pickBestAudioTrackIndex,
  enforceMuxedHlsAudio,
  codecsFromHlsManifest,
  notifyIfAudioCodecUnsupported,
  detectNoPlayableHlsAudio,
  dispatchHlsNoAudioDetected,
  getCurrentLevelCodecString,
  levelCodecsHaveMuxedAudio,
} from "@/scripts/lib/embedded-hls-audio"
import {
  clearTrackPreference,
  findPreferredTrackIndex,
  saveTrackPreference,
} from "@/scripts/lib/media-track-preferences"
import { removeNativeTrackSettings } from "@/scripts/lib/embedded-native-tracks.js"
import { formatMediaTrackLabel } from "@/scripts/lib/media-track-labels.js"
import {
  trackSettingsDebug,
  type ArtplayerSelectorRow,
} from "@/scripts/lib/artplayer-track-settings.js"

const SETTING_AUDIO = "xt-hls-audio"
const SETTING_SUBTITLE = "xt-hls-subtitle"
const NO_AUDIO_CHECK_MS = 4500

function writeHlsDebug(detail: unknown): void {
  if (!import.meta.env.DEV) return
  try {
    let node = document.getElementById("xt-hls-debug-log")
    if (!node) {
      node = document.createElement("script")
      node.id = "xt-hls-debug-log"
      node.type = "application/json"
      document.body.appendChild(node)
    }
    node.textContent = JSON.stringify(detail)
  } catch {}
}

function audioTrackLabel(
  track: { name?: string; lang?: string; groupId?: string; codec?: string },
  index: number,
): string {
  return formatMediaTrackLabel(
    {
      name: track.name,
      lang: track.lang,
      groupId: track.groupId,
      codec: track.codec,
    },
    index,
    "audio",
  )
}

function subtitleTrackLabel(
  track: { name?: string; lang?: string; id?: string },
  index: number,
): string {
  return formatMediaTrackLabel(
    { name: track.name, lang: track.lang, id: track.id },
    index,
    "subtitle",
  )
}

function currentLevelAudioCodec(hls: {
  levels?: Array<{ audioCodec?: string; codecs?: string }>
  currentLevel?: number
}): string {
  return getCurrentLevelCodecString(hls)
}

function shortTrackHint(value: string): string {
  const clean = String(value || "").replace(/\s+/g, " ").trim()
  if (!clean) return ""
  return clean.length > 28 ? `${clean.slice(0, 25)}...` : clean
}

function settingTitle(title: string, hint: string): string {
  const compact = shortTrackHint(hint)
  return compact
    ? `${title} <span class="opacity-70 text-2xs">· ${compact}</span>`
    : title
}

function applyPreferredHlsTracks(hls: any, opts: { audio?: boolean; subtitle?: boolean } = {}): void {
  if (!hls) return
  if (opts.audio !== false) {
    const audioIndex = findPreferredTrackIndex("audio", hls.audioTracks || [])
    if (audioIndex >= 0 && hls.audioTrack !== audioIndex) {
      hls.audioTrack = audioIndex
      log.log("[xt:player] HLS preferred audio", audioIndex)
    }
  }
  if (opts.subtitle !== false) {
    const subtitleIndex = findPreferredTrackIndex("subtitle", hls.subtitleTracks || [])
    if (subtitleIndex >= 0 && hls.subtitleTrack !== subtitleIndex) {
      hls.subtitleTrack = subtitleIndex
      hls.subtitleDisplay = true
      log.log("[xt:player] HLS preferred subtitle", subtitleIndex)
    }
  }
}

export function refreshHlsTrackSettings(art: any, hls: any): void {
  if (!art?.setting || !hls) return

  removeNativeTrackSettings(art)

  try {
    art.setting.remove(SETTING_AUDIO)
  } catch {}
  try {
    art.setting.remove(SETTING_SUBTITLE)
  } catch {}

  const audioTracks = hls.audioTracks || []
  if (import.meta.env.DEV) {
    log.log("[xt:player] HLS track menu", {
      audio: audioTracks.length,
      subtitle: (hls.subtitleTracks || []).length,
    })
  }
  const currentAudio =
    typeof hls.audioTrack === "number" ? hls.audioTrack : pickBestAudioTrackIndex(hls)
  const embeddedLabel = t("player.track.audioEmbedded") || "Default (main stream)"
  const codecHint = currentLevelAudioCodec(hls)
  const muxedHint = levelCodecsHaveMuxedAudio(codecHint)
    ? ""
    : ` · ${t("player.track.audioExternal") || "external audio"}`
  const activeAudioLabel =
    currentAudio === -1
      ? embeddedLabel
      : audioTrackLabel(audioTracks[currentAudio] || {}, currentAudio)

  const audioSelector: ArtplayerSelectorRow[] = [
    {
      html: embeddedLabel + (muxedHint ? "" : " ⚠"),
      default: currentAudio === -1,
      _xtKind: "hls-audio-muxed",
    },
    ...audioTracks.map(
      (
        track: { name?: string; lang?: string; groupId?: string; codec?: string },
        index: number,
      ) => ({
        html: audioTrackLabel(track, index),
        default: currentAudio === index,
        _xtKind: "hls-audio",
        _xtPayload: { track, index },
      }),
    ),
  ]

  if (audioTracks.length === 0) {
    audioSelector.push({
      html:
        t("player.track.audioEmbeddedOnly") ||
        "Only the main audio track is available on this stream",
      _xtKind: "noop",
    })
  }

  if (codecHint) {
    audioSelector.push({
      html: `${t("player.track.codec") || "Codec"}: ${codecHint}`,
      _xtKind: "noop",
    })
  }

  art.setting.add({
    name: SETTING_AUDIO,
    html: settingTitle(t("player.menu.audio") || "Audio", activeAudioLabel),
    width: 280,
    selector: audioSelector,
    onSelect(item: ArtplayerSelectorRow) {
      trackSettingsDebug("hls.audio.menu.select", { kind: item?._xtKind, html: item?.html })
      if (item?._xtKind === "hls-audio-muxed") {
        hls.audioTrack = -1
        clearTrackPreference("audio")
        enforceMuxedHlsAudio(hls)
        ensureVideoAudible(art.video, art)
        return item.html || ""
      }
      const payload = item?._xtPayload as
        | { track: { name?: string; lang?: string }; index: number }
        | undefined
      if (item?._xtKind === "hls-audio" && payload) {
        hls.audioTrack = payload.index
        saveTrackPreference("audio", payload.track)
        ensureVideoAudible(art.video, art)
        trackSettingsDebug("hls.audio.applied", { index: payload.index })
      }
      return item?.html || ""
    },
  })

  const subtitleTracks = hls.subtitleTracks || []
  const currentSubtitle = hls.subtitleTrack ?? -1
  const activeSubtitleLabel =
    currentSubtitle === -1
      ? t("player.subtitle.off") || "Off"
      : subtitleTrackLabel(subtitleTracks[currentSubtitle] || {}, currentSubtitle)
  const subtitleSelector: ArtplayerSelectorRow[] = [
    {
      html: t("player.subtitle.off") || "Off",
      default: currentSubtitle === -1,
      _xtKind: "hls-subtitle-off",
    },
    ...subtitleTracks.map(
      (track: { name?: string; lang?: string; id?: string }, index: number) => ({
        html: subtitleTrackLabel(track, index),
        default: currentSubtitle === index,
        _xtKind: "hls-subtitle",
        _xtPayload: { track, index },
      }),
    ),
  ]

  if (subtitleTracks.length === 0) {
    subtitleSelector.push({
      html: t("player.subtitle.unavailable") || "Not available on this stream",
      _xtKind: "noop",
    })
  }

  art.setting.add({
    name: SETTING_SUBTITLE,
    html: settingTitle(t("player.menu.subtitle") || "Subtitles", activeSubtitleLabel),
    width: 280,
    selector: subtitleSelector,
    onSelect(item: ArtplayerSelectorRow) {
      trackSettingsDebug("hls.subtitle.menu.select", { kind: item?._xtKind })
      if (item?._xtKind === "hls-subtitle-off") {
        hls.subtitleTrack = -1
        hls.subtitleDisplay = false
        clearTrackPreference("subtitle")
        return item.html || ""
      }
      const payload = item?._xtPayload as
        | { track: { name?: string; lang?: string; id?: string }; index: number }
        | undefined
      if (item?._xtKind === "hls-subtitle" && payload) {
        hls.subtitleTrack = payload.index
        hls.subtitleDisplay = true
        saveTrackPreference("subtitle", payload.track)
        if (art.video) {
          for (const tr of Array.from(art.video.textTracks || [])) {
            tr.mode = "disabled"
          }
        }
        trackSettingsDebug("hls.subtitle.applied", { index: payload.index })
      }
      return item?.html || ""
    },
  })
}

declare const __XT_PLAYBACK_BUILD__: string | undefined

export interface WireHlsOptions {
  /** Live TV: auto-pick muxed/AAC audio. VOD: expose tracks, minimal auto-switching. */
  live?: boolean
}

function scheduleVodTrackRefresh(art: any, hls: any, isLive: boolean): void {
  if (isLive) {
    setTimeout(() => refreshHlsTrackSettings(art, hls), 400)
    return
  }
  for (const delay of [400, 1200, 2500]) {
    setTimeout(() => {
      if (!art?.hls || art.hls !== hls) return
      refreshHlsTrackSettings(art, hls)
    }, delay)
  }
}

function nudgeLiveToEdge(video: HTMLVideoElement): void {
  try {
    if (video.currentTime > 0.5) return
    const seekable = video.seekable
    if (!seekable || seekable.length === 0) return
    const end = seekable.end(seekable.length - 1)
    const start = seekable.start(seekable.length - 1)
    if (!Number.isFinite(end) || end <= 0) return
    video.currentTime = Math.max(start, end - 12)
    const playPromise = video.play?.()
    if (playPromise && typeof playPromise.catch === "function") {
      playPromise.catch(() => {})
    }
  } catch {}
}

export function wireHlsForArtplayer(
  art: any,
  hls: any,
  video: HTMLVideoElement,
  options: WireHlsOptions = {},
): void {
  const Hls = hls?.constructor
  if (!Hls?.Events) return
  const isLive = options.live === true

  if (import.meta.env.DEV) {
    try {
      ;(window as any).__xtLastHls = hls
    } catch {}
    log.log("[xt:player] playback build", __XT_PLAYBACK_BUILD__ || "unknown")
  }
  writeHlsDebug({ event: "attached", live: isLive })

  art.hls = hls
  let noAudioCheckTimer: ReturnType<typeof setTimeout> | null = null
  let noAudioDispatched = false

  const checkPlayableAudio = () => {
    const blocked = detectNoPlayableHlsAudio(hls)
    if (blocked.blocked) {
      notifyIfAudioCodecUnsupported(blocked.codecs || "")
      if (!noAudioDispatched) {
        noAudioDispatched = true
        dispatchHlsNoAudioDetected(blocked)
      }
      return true
    }
    return false
  }

  const syncAudio = () => {
    if (isLive) {
      enforceMuxedHlsAudio(hls)
      const idx = pickBestAudioTrackIndex(hls)
      if (hls.audioTrack !== idx) {
        hls.audioTrack = idx
        log.log("[xt:player] HLS audio auto", idx === -1 ? "muxed" : idx)
      }
    }
    ensureVideoAudible(video, art)
    checkPlayableAudio()
  }

  const scheduleNoAudioWatch = () => {
    if (!isLive) return
    if (noAudioCheckTimer) clearTimeout(noAudioCheckTimer)
    noAudioCheckTimer = setTimeout(() => {
      noAudioCheckTimer = null
      if (video.paused || video.ended) return
      if (video.videoWidth === 0) return
      ensureVideoAudible(video, art)
      if (checkPlayableAudio()) return
      if (video.currentTime < 2) return
      const blocked = detectNoPlayableHlsAudio(hls)
      if (blocked.blocked && !noAudioDispatched) {
        noAudioDispatched = true
        log.warn("[xt:player] HLS playing without playable audio", blocked)
        dispatchHlsNoAudioDetected(blocked)
      }
    }, NO_AUDIO_CHECK_MS)
  }

  const onTracksUpdated = () => {
    noAudioDispatched = false
    if (!isLive) applyPreferredHlsTracks(hls)
    syncAudio()
    refreshHlsTrackSettings(art, hls)
  }

  hls.on(Hls.Events.MANIFEST_PARSED, (_event: string, data: unknown) => {
    writeHlsDebug({
      event: "manifest",
      levels: hls.levels?.map((level: { codecs?: string; audioCodec?: string; videoCodec?: string }) => ({
        codecs: level.codecs,
        audioCodec: level.audioCodec,
        videoCodec: level.videoCodec,
      })),
      audioTracks: hls.audioTracks,
    })
    noAudioDispatched = false
    if (!isLive) applyPreferredHlsTracks(hls)
    syncAudio()
    notifyIfAudioCodecUnsupported(
      codecsFromHlsManifest(data as { levels?: Array<{ codecs?: string; audioCodec?: string }> }),
    )
    refreshHlsTrackSettings(art, hls)
    scheduleVodTrackRefresh(art, hls, isLive)
  })

  hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, onTracksUpdated)
  hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, onTracksUpdated)

  hls.on(Hls.Events.LEVEL_SWITCHED, () => {
    noAudioDispatched = false
    if (isLive) enforceMuxedHlsAudio(hls)
    ensureVideoAudible(video, art)
    checkPlayableAudio()
  })

  hls.on(Hls.Events.AUDIO_TRACK_SWITCHED, () => {
    if (isLive) enforceMuxedHlsAudio(hls)
    refreshHlsTrackSettings(art, hls)
  })

  hls.on(Hls.Events.SUBTITLE_TRACK_SWITCH, () => {
    refreshHlsTrackSettings(art, hls)
  })

  hls.on(Hls.Events.FRAG_LOADED, (_event: string, data: { frag?: { url?: string; sn?: number | string } }) => {
    writeHlsDebug({
      event: "frag-loaded",
      sn: data?.frag?.sn,
      url: data?.frag?.url?.replace(/\/hls\/[^/]+\//i, "/hls/***/"),
      currentTime: video.currentTime,
      readyState: video.readyState,
      buffered: Array.from({ length: video.buffered.length }, (_unused, index) => [
        video.buffered.start(index),
        video.buffered.end(index),
      ]),
    })
  })

  hls.on(Hls.Events.BUFFER_APPENDED, () => {
    if (isLive) nudgeLiveToEdge(video)
    writeHlsDebug({
      event: "buffer-appended",
      currentTime: video.currentTime,
      readyState: video.readyState,
      buffered: Array.from({ length: video.buffered.length }, (_unused, index) => [
        video.buffered.start(index),
        video.buffered.end(index),
      ]),
    })
  })

  hls.on(Hls.Events.ERROR, (_event: string, data: { type?: string; details?: string; fatal?: boolean; response?: { code?: number } }) => {
    const details = data?.details || ""
    const httpCode = data?.response?.code
    const manifestAuthFailure =
      /manifestLoadError|manifestParsingError|levelLoadError/i.test(details) &&
      (httpCode === 401 || httpCode === 403)
    const logFn = manifestAuthFailure ? log.debug.bind(log) : log.warn.bind(log)
    if (import.meta.env.DEV) {
      logFn("[xt:player] HLS error", {
        type: data?.type,
        details,
        fatal: data?.fatal,
        httpCode,
        currentTime: video.currentTime,
        readyState: video.readyState,
        networkState: video.networkState,
      })
    }
    try {
      window.dispatchEvent(
        new CustomEvent("xt:hls-debug-error", {
          detail: {
            type: data?.type,
            details,
            fatal: data?.fatal,
            currentTime: video.currentTime,
            readyState: video.readyState,
            networkState: video.networkState,
          },
        }),
      )
    } catch {}
    writeHlsDebug({
      event: "error",
      type: data?.type,
      details,
      fatal: data?.fatal,
      currentTime: video.currentTime,
      readyState: video.readyState,
      networkState: video.networkState,
      levels: hls.levels?.map((level: { codecs?: string; audioCodec?: string }) => ({
        codecs: level.codecs,
        audioCodec: level.audioCodec,
      })),
      audioTracks: hls.audioTracks,
    })
    const codecRelated =
      /bufferAppendError|bufferIncompatibleCodecsError|manifestIncompatibleCodecsError/i.test(
        details,
      )
    if (codecRelated) {
      notifyIfAudioCodecUnsupported(codecsFromHlsManifest({ levels: hls.levels }))
      if (!noAudioDispatched) {
        noAudioDispatched = true
        dispatchHlsNoAudioDetected({ reason: details })
      }
    }
    if (!data?.fatal) return
    try {
      if (/media/i.test(data.type || "")) {
        hls.recoverMediaError?.()
        return
      }
      if (/network/i.test(data.type || "")) {
        hls.startLoad?.()
      }
    } catch {}
  })

  if (isLive) {
    video.addEventListener("playing", () => {
      ensureVideoAudible(video, art)
      scheduleNoAudioWatch()
    })
    art.on("video:playing", () => {
      ensureVideoAudible(video, art)
      scheduleNoAudioWatch()
    })
  } else {
    art.on("video:playing", () => ensureVideoAudible(video, art))
  }

  art.on("destroy", () => {
    if (noAudioCheckTimer) clearTimeout(noAudioCheckTimer)
  })
}
