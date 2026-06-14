import { t } from "@/scripts/lib/i18n.js"
import { isContainerUrl, useDevStreamProxy } from "@/scripts/lib/stream-proxy"
import { isXtreamVodContainerUrl } from "@/scripts/lib/embedded-vod-playback.js"
import {
  clearTrackPreference,
  findPreferredTrackIndex,
  saveTrackPreference,
} from "@/scripts/lib/media-track-preferences"
import { formatMediaTrackLabel } from "@/scripts/lib/media-track-labels.js"
import {
  trackSettingsDebug,
  type ArtplayerSelectorRow,
} from "@/scripts/lib/artplayer-track-settings.js"

export const NATIVE_SETTING_AUDIO = "xt-native-audio"
export const NATIVE_SETTING_SUBTITLE = "xt-native-subtitle"

const SETTING_AUDIO = NATIVE_SETTING_AUDIO
const SETTING_SUBTITLE = NATIVE_SETTING_SUBTITLE

export function removeNativeTrackSettings(art: any): void {
  try {
    art.setting.remove(SETTING_AUDIO)
  } catch {}
  try {
    art.setting.remove(SETTING_SUBTITLE)
  } catch {}
}

function isAdaptiveArtplayerType(type: unknown): boolean {
  return type === "m3u8" || type === "ts" || type === "mpd"
}

export function shouldWireNativeTracks(art: any): boolean {
  if (!art || art.hls) return false
  if (art._xtContainerTracks || art._xtPendingContainerTracks) return false
  // Live / HLS / TS / DASH: track menus come from embedded-hls-tracks (or Shaka).
  if (art.option?.isLive) return false
  if (isAdaptiveArtplayerType(art.type)) return false
  if (!useDevStreamProxy()) return true
  const probe =
    (typeof art._xtContainerProbeUrl === "string" && art._xtContainerProbeUrl) ||
    (typeof art._xtVodSourceUrl === "string" && art._xtVodSourceUrl) ||
    ""
  if (!probe) return true
  // Film/serie Xtream: menu ffprobe/ffmpeg o hls.js, non audioTracks nativi (non commutabili).
  if (isContainerUrl(probe) || isXtreamVodContainerUrl(probe)) {
    return false
  }
  return true
}

function refreshNativeAudioSettings(art: any, video: HTMLVideoElement): void {
  if (!shouldWireNativeTracks(art)) return
  const tracks = (video as any).audioTracks

  try {
    art.setting.remove(SETTING_AUDIO)
  } catch {}

  const selector: ArtplayerSelectorRow[] = []
  if (!tracks || tracks.length === 0) {
    selector.push({
      html:
        t("player.track.audioEmbeddedOnly") ||
        "Use the HLS stream for multiple audio tracks (browser limitation)",
      _xtKind: "noop",
    })
    art.setting.add({
      name: SETTING_AUDIO,
      html: t("player.menu.audio") || "Audio",
      width: 280,
      selector,
    })
    return
  }
  const preferred = findPreferredTrackIndex("audio", tracks)
  if (preferred >= 0) {
    for (let j = 0; j < tracks.length; j++) {
      tracks[j].enabled = j === preferred
    }
  }
  for (let i = 0; i < tracks.length; i++) {
    const track = tracks[i]
    const label = formatMediaTrackLabel(
      { label: track.label, language: track.language, id: track.id },
      i,
      "audio",
    )
    selector.push({
      html: label,
      default: track.enabled,
      _xtKind: "native-audio",
      _xtPayload: { index: i, track },
    })
  }

  art.setting.add({
    name: SETTING_AUDIO,
    html: t("player.menu.audio") || "Audio",
    width: 280,
    selector,
    onSelect(item: ArtplayerSelectorRow) {
      const payload = item?._xtPayload as { index: number; track: unknown } | undefined
      if (item?._xtKind !== "native-audio" || !payload) return item?.html || ""
      const { index, track } = payload
      for (let j = 0; j < tracks.length; j++) {
        tracks[j].enabled = j === index
      }
      saveTrackPreference("audio", track)
      trackSettingsDebug("native.audio.applied", { index })
      return item.html || ""
    },
  })
}

function refreshNativeSubtitleSettings(art: any, video: HTMLVideoElement): void {
  if (!shouldWireNativeTracks(art)) return
  try {
    art.setting.remove(SETTING_SUBTITLE)
  } catch {}

  const textTracks = Array.from(video.textTracks || [])
  const subtitleTracks = textTracks.filter(
    (tr) => tr.kind === "subtitles" || tr.kind === "captions",
  )
  const preferred = findPreferredTrackIndex("subtitle", subtitleTracks)
  if (preferred >= 0) {
    for (const tr of textTracks) {
      tr.mode = "disabled"
    }
    subtitleTracks[preferred].mode = "showing"
  }

  const selector: ArtplayerSelectorRow[] = [
    {
      html: t("player.subtitle.off") || "Off",
      default: subtitleTracks.every((tr) => tr.mode === "disabled" || tr.mode === "hidden"),
      _xtKind: "native-subtitle-off",
    },
    ...subtitleTracks.map((track, index) => ({
      html: formatMediaTrackLabel(
        { label: track.label, language: track.language },
        index,
        "subtitle",
      ),
      default: track.mode === "showing",
      _xtKind: "native-subtitle",
      _xtPayload: { index, track },
    })),
  ]

  if (subtitleTracks.length === 0) {
    selector.push({
      html: t("player.subtitle.unavailable") || "Not available on this stream",
      _xtKind: "noop",
    })
  }

  art.setting.add({
    name: SETTING_SUBTITLE,
    html: t("player.menu.subtitle") || "Subtitles",
    width: 280,
    selector,
    onSelect(item: ArtplayerSelectorRow) {
      if (item?._xtKind === "native-subtitle-off") {
        for (const tr of textTracks) {
          tr.mode = "disabled"
        }
        clearTrackPreference("subtitle")
        return item.html || ""
      }
      const payload = item?._xtPayload as { index: number; track: TextTrack } | undefined
      if (item?._xtKind === "native-subtitle" && payload) {
        for (const tr of textTracks) {
          tr.mode = "disabled"
        }
        payload.track.mode = "showing"
        saveTrackPreference("subtitle", payload.track)
        trackSettingsDebug("native.subtitle.applied", { index: payload.index })
      }
      return item?.html || ""
    },
  })
}

export function refreshNativeTrackSettings(art: any, video: HTMLVideoElement | null): void {
  if (!art?.setting || !video) return
  if (!shouldWireNativeTracks(art)) {
    removeNativeTrackSettings(art)
    return
  }
  refreshNativeAudioSettings(art, video)
  refreshNativeSubtitleSettings(art, video)
}

export function wireNativeTracksForArtplayer(art: any): void {
  const refresh = () => {
    refreshNativeTrackSettings(art, art.video)
  }
  art.on("video:loadedmetadata", refresh)
  art.on("video:loadeddata", refresh)
  ;(art.video as any)?.audioTracks?.addEventListener?.("addtrack", refresh)
  ;(art.video as any)?.audioTracks?.addEventListener?.("change", refresh)
  art.video?.textTracks?.addEventListener?.("addtrack", refresh)
  art.video?.textTracks?.addEventListener?.("change", refresh)
  art.on("video:emptied", () => {
    try {
      art.setting.remove(SETTING_AUDIO)
    } catch {}
    try {
      art.setting.remove(SETTING_SUBTITLE)
    } catch {}
  })
}
