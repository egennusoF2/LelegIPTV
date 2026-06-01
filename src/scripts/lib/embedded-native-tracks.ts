import { log } from "@/scripts/lib/log.js"
import { t } from "@/scripts/lib/i18n.js"

const SETTING_AUDIO = "xt-native-audio"
const SETTING_SUBTITLE = "xt-native-subtitle"

function refreshNativeAudioSettings(art: any, video: HTMLVideoElement): void {
  const tracks = (video as any).audioTracks
  if (!tracks || tracks.length === 0) return

  try {
    art.setting.remove(SETTING_AUDIO)
  } catch {}

  const selector: Array<{ html: string; default?: boolean; onSelect?: () => void }> = []
  for (let i = 0; i < tracks.length; i++) {
    const track = tracks[i]
    const label =
      [track.label, track.language, track.id].filter(Boolean).join(" · ") ||
      `${t("player.track.audio") || "Audio"} ${i + 1}`
    selector.push({
      html: label,
      default: track.enabled,
      onSelect() {
        for (let j = 0; j < tracks.length; j++) {
          tracks[j].enabled = j === i
        }
        log.log("[xt:player] native audio track", i, label)
      },
    })
  }

  art.setting.add({
    name: SETTING_AUDIO,
    html: t("player.menu.audio") || "Audio",
    width: 280,
    selector,
  })
}

function refreshNativeSubtitleSettings(art: any, video: HTMLVideoElement): void {
  try {
    art.setting.remove(SETTING_SUBTITLE)
  } catch {}

  const textTracks = Array.from(video.textTracks || [])
  const subtitleTracks = textTracks.filter(
    (tr) => tr.kind === "subtitles" || tr.kind === "captions",
  )

  const selector: Array<{ html: string; default?: boolean; onSelect?: () => void }> = [
    {
      html: t("player.subtitle.off") || "Off",
      default: subtitleTracks.every((tr) => tr.mode === "disabled" || tr.mode === "hidden"),
      onSelect() {
        for (const tr of textTracks) {
          tr.mode = "disabled"
        }
      },
    },
    ...subtitleTracks.map((track, index) => ({
      html:
        [track.label, track.language].filter(Boolean).join(" · ") ||
        `${t("player.track.subtitle") || "Subtitle"} ${index + 1}`,
      default: track.mode === "showing",
      onSelect() {
        for (const tr of textTracks) {
          tr.mode = "disabled"
        }
        track.mode = "showing"
        log.log("[xt:player] native subtitle track", index, track.label)
      },
    })),
  ]

  if (subtitleTracks.length === 0) return

  art.setting.add({
    name: SETTING_SUBTITLE,
    html: t("player.menu.subtitle") || "Subtitles",
    width: 280,
    selector,
  })
}

export function refreshNativeTrackSettings(art: any, video: HTMLVideoElement | null): void {
  if (!art?.setting || !video) return
  if (art.hls) return
  refreshNativeAudioSettings(art, video)
  refreshNativeSubtitleSettings(art, video)
}

export function wireNativeTracksForArtplayer(art: any): void {
  const refresh = () => {
    if (art.hls) return
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
