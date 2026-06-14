/**
 * Video.js + external hls.js: audio/subtitle menus (ArtPlayer uses art.setting).
 */
import { log } from "@/scripts/lib/log.js"
import { t } from "@/scripts/lib/i18n.js"
import { applyPreferredHlsTracks } from "@/scripts/lib/embedded-hls-tracks"
import { ensureVideoAudible } from "@/scripts/lib/embedded-hls-audio"
import { clearTrackPreference, saveTrackPreference } from "@/scripts/lib/media-track-preferences"
import { formatMediaTrackLabel } from "@/scripts/lib/media-track-labels"

type VjsPlayer = {
  el?: () => HTMLElement | null
  on?: (event: string, fn: () => void) => void
  off?: (event: string, fn: () => void) => void
}

function trackBarRoot(player: VjsPlayer): HTMLElement | null {
  const el = player.el?.()
  if (!el) return null
  return el.querySelector(".video-js") || el
}

function ensureTrackBar(player: VjsPlayer): HTMLElement | null {
  const root = trackBarRoot(player)
  if (!root) return null
  let bar = root.querySelector<HTMLElement>("[data-xt-vjs-tracks]")
  if (!bar) {
    bar = document.createElement("div")
    bar.dataset.xtVjsTracks = "1"
    bar.className =
      "xt-vjs-tracks absolute top-2 right-2 z-20 flex gap-2 text-xs pointer-events-auto"
    root.appendChild(bar)
  }
  return bar
}

function fillSelect(
  select: HTMLSelectElement,
  items: Array<{ value: string; label: string }>,
  current: string,
): void {
  select.replaceChildren()
  for (const item of items) {
    const opt = document.createElement("option")
    opt.value = item.value
    opt.textContent = item.label
    select.appendChild(opt)
  }
  select.value = current
}

function wireHlsTrackBar(player: VjsPlayer, hls: any, video: HTMLVideoElement): void {
  const bar = ensureTrackBar(player)
  if (!bar || !hls) return

  const audioTracks = hls.audioTracks || []
  const subtitleTracks = hls.subtitleTracks || []
  const currentAudio =
    typeof hls.audioTrack === "number" ? String(hls.audioTrack) : "-1"
  const currentSubtitle =
    typeof hls.subtitleTrack === "number" ? String(hls.subtitleTrack) : "-1"

  bar.replaceChildren()

  if (audioTracks.length > 0) {
    const audioWrap = document.createElement("label")
    audioWrap.className = "flex items-center gap-1 bg-black/60 text-white px-2 py-1 rounded"
    const audioLabel = document.createElement("span")
    audioLabel.textContent = t("player.menu.audio") || "Audio"
    const audioSelect = document.createElement("select")
    audioSelect.className = "bg-transparent text-white max-w-[10rem]"
    fillSelect(
      audioSelect,
      [
        {
          value: "-1",
          label: t("player.track.audioEmbedded") || "Default",
        },
        ...audioTracks.map(
          (
            track: { name?: string; lang?: string; groupId?: string },
            index: number,
          ) => ({
            value: String(index),
            label: formatMediaTrackLabel(
              { name: track.name, lang: track.lang, groupId: track.groupId },
              index,
              "audio",
            ),
          }),
        ),
      ],
      currentAudio,
    )
    audioSelect.addEventListener("change", () => {
      const idx = Number(audioSelect.value)
      hls.audioTrack = idx
      if (idx >= 0 && audioTracks[idx]) {
        saveTrackPreference("audio", audioTracks[idx])
      } else {
        clearTrackPreference("audio")
      }
      ensureVideoAudible(video, null)
    })
    audioWrap.append(audioLabel, audioSelect)
    bar.appendChild(audioWrap)
  }

  if (subtitleTracks.length > 0) {
    const subWrap = document.createElement("label")
    subWrap.className = "flex items-center gap-1 bg-black/60 text-white px-2 py-1 rounded"
    const subLabel = document.createElement("span")
    subLabel.textContent = t("player.menu.subtitle") || "Subs"
    const subSelect = document.createElement("select")
    subSelect.className = "bg-transparent text-white max-w-[10rem]"
    fillSelect(
      subSelect,
      [
        {
          value: "-1",
          label: t("player.subtitle.off") || "Off",
        },
        ...subtitleTracks.map(
          (track: { name?: string; lang?: string; id?: string }, index: number) => ({
            value: String(index),
            label: formatMediaTrackLabel(
              { name: track.name, lang: track.lang, id: track.id },
              index,
              "subtitle",
            ),
          }),
        ),
      ],
      currentSubtitle,
    )
    subSelect.addEventListener("change", () => {
      const idx = Number(subSelect.value)
      hls.subtitleTrack = idx
      hls.subtitleDisplay = idx >= 0
      if (idx >= 0 && subtitleTracks[idx]) {
        saveTrackPreference("subtitle", subtitleTracks[idx])
        for (const tr of Array.from(video.textTracks || [])) {
          tr.mode = "disabled"
        }
      } else {
        clearTrackPreference("subtitle")
      }
    })
    subWrap.append(subLabel, subSelect)
    bar.appendChild(subWrap)
  }

  if (import.meta.env.DEV && (audioTracks.length || subtitleTracks.length)) {
    log.log("[xt:player] Video.js HLS tracks", {
      audio: audioTracks.length,
      subtitle: subtitleTracks.length,
    })
  }
}

export interface WireVideoJsHlsOptions {
  live?: boolean
}

/** Wire hls.js track events for Video.js (settings gear is ArtPlayer-only). */
export function wireHlsForVideojs(
  player: VjsPlayer,
  hls: any,
  video: HTMLVideoElement,
  options: WireVideoJsHlsOptions = {},
): void {
  const Hls = hls?.constructor
  if (!Hls?.Events) return
  const isLive = options.live === true

  const refresh = () => {
    applyPreferredHlsTracks(hls, { audio: true, subtitle: true })
    wireHlsTrackBar(player, hls, video)
  }

  hls.on(Hls.Events.MANIFEST_PARSED, () => {
    if (!isLive) applyPreferredHlsTracks(hls)
    refresh()
  })
  hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, refresh)
  hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, refresh)
  hls.on(Hls.Events.AUDIO_TRACK_SWITCHED, refresh)
  hls.on(Hls.Events.SUBTITLE_TRACK_SWITCH, refresh)

  if (!isLive) {
    for (const delay of [500, 1500, 3000]) {
      setTimeout(() => {
        if (!hls) return
        refresh()
      }, delay)
    }
  }

  player.on?.("dispose", () => {
    try {
      trackBarRoot(player)?.querySelector("[data-xt-vjs-tracks]")?.remove()
    } catch {}
  })
}
