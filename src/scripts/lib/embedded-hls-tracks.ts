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

const SETTING_AUDIO = "xt-hls-audio"
const SETTING_SUBTITLE = "xt-hls-subtitle"
const NO_AUDIO_CHECK_MS = 4500

function audioTrackLabel(
  track: { name?: string; lang?: string; groupId?: string; codec?: string },
  index: number,
): string {
  const parts = [track.name, track.lang, track.groupId, track.codec].filter(Boolean)
  return parts.length ? parts.join(" · ") : `${t("player.track.audio") || "Audio"} ${index + 1}`
}

function subtitleTrackLabel(
  track: { name?: string; lang?: string; id?: string },
  index: number,
): string {
  const parts = [track.name, track.lang, track.id].filter(Boolean)
  return parts.length ? parts.join(" · ") : `${t("player.track.subtitle") || "Subtitle"} ${index + 1}`
}

function currentLevelAudioCodec(hls: {
  levels?: Array<{ audioCodec?: string; codecs?: string }>
  currentLevel?: number
}): string {
  return getCurrentLevelCodecString(hls)
}

export function refreshHlsTrackSettings(art: any, hls: any): void {
  if (!art?.setting || !hls) return

  try {
    art.setting.remove(SETTING_AUDIO)
  } catch {}
  try {
    art.setting.remove(SETTING_SUBTITLE)
  } catch {}

  const audioTracks = hls.audioTracks || []
  const currentAudio =
    typeof hls.audioTrack === "number" ? hls.audioTrack : pickBestAudioTrackIndex(hls)
  const embeddedLabel = t("player.track.audioEmbedded") || "Default (main stream)"
  const codecHint = currentLevelAudioCodec(hls)
  const muxedHint = levelCodecsHaveMuxedAudio(codecHint)
    ? ""
    : ` · ${t("player.track.audioExternal") || "external audio"}`

  const audioSelector: Array<{
    html: string
    default?: boolean
    onSelect?: () => void
  }> = [
    {
      html: embeddedLabel + (muxedHint ? "" : " ⚠"),
      default: currentAudio === -1,
      onSelect() {
        hls.audioTrack = -1
        enforceMuxedHlsAudio(hls)
        ensureVideoAudible(art.video, art)
        log.log("[xt:player] HLS audio: muxed main stream")
      },
    },
    ...audioTracks.map(
      (
        track: { name?: string; lang?: string; groupId?: string; codec?: string },
        index: number,
      ) => ({
        html: audioTrackLabel(track, index),
        default: currentAudio === index,
        onSelect() {
          hls.audioTrack = index
          ensureVideoAudible(art.video, art)
          log.log("[xt:player] HLS audio alternate", index, track)
        },
      }),
    ),
  ]

  if (codecHint) {
    audioSelector.push({
      html: `${t("player.track.codec") || "Codec"}: ${codecHint}`,
      onSelect() {},
    })
  }

  art.setting.add({
    name: SETTING_AUDIO,
    html: t("player.menu.audio") || "Audio",
    width: 280,
    selector: audioSelector,
  })

  const subtitleTracks = hls.subtitleTracks || []
  const subtitleSelector: Array<{
    html: string
    default?: boolean
    onSelect?: () => void
  }> = [
    {
      html: t("player.subtitle.off") || "Off",
      default: (hls.subtitleTrack ?? -1) === -1,
      onSelect() {
        hls.subtitleTrack = -1
        hls.subtitleDisplay = false
      },
    },
    ...subtitleTracks.map(
      (track: { name?: string; lang?: string; id?: string }, index: number) => ({
        html: subtitleTrackLabel(track, index),
        default: hls.subtitleTrack === index,
        onSelect() {
          hls.subtitleTrack = index
          hls.subtitleDisplay = true
        },
      }),
    ),
  ]

  if (subtitleTracks.length === 0) {
    subtitleSelector.push({
      html: t("player.subtitle.unavailable") || "Not available on this stream",
      onSelect() {},
    })
  }

  art.setting.add({
    name: SETTING_SUBTITLE,
    html: t("player.menu.subtitle") || "Subtitles",
    width: 280,
    selector: subtitleSelector,
  })
}

declare const __XT_PLAYBACK_BUILD__: string | undefined

export interface WireHlsOptions {
  /** Live TV: auto-pick muxed/AAC audio. VOD: expose tracks, minimal auto-switching. */
  live?: boolean
}

export function wireHlsForArtplayer(
  art: any,
  hls: any,
  video: HTMLVideoElement,
  options: WireHlsOptions = {},
): void {
  const Hls = hls?.constructor
  if (!Hls?.Events) return
  const isLive = options.live !== false

  if (import.meta.env.DEV) {
    log.log("[xt:player] playback build", __XT_PLAYBACK_BUILD__ || "unknown")
  }

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
    syncAudio()
    refreshHlsTrackSettings(art, hls)
  }

  hls.on(Hls.Events.MANIFEST_PARSED, (_event: string, data: unknown) => {
    noAudioDispatched = false
    syncAudio()
    notifyIfAudioCodecUnsupported(
      codecsFromHlsManifest(data as { levels?: Array<{ codecs?: string; audioCodec?: string }> }),
    )
    refreshHlsTrackSettings(art, hls)
    setTimeout(() => refreshHlsTrackSettings(art, hls), 400)
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

  hls.on(Hls.Events.ERROR, (_event: string, data: { type?: string; details?: string }) => {
    const details = data?.details || ""
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
