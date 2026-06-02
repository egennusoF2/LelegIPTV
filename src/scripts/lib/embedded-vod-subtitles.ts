import { log } from "@/scripts/lib/log.js"
import {
  devProxyFetchHeaders,
  useDevStreamProxy,
} from "@/scripts/lib/stream-proxy"
import { resolveMediaHeaders } from "@/scripts/lib/embedded-media-fetch.js"

const VOD_SUBTITLE_PATH = "/__vod_subtitles"

interface ExtractedSubtitleTrack {
  src: string
  label?: string
  language?: string
}

function canExtractDevSubtitles(url: string): boolean {
  if (!useDevStreamProxy()) return false
  if (!/\.(mkv|avi|ts|mp4)(?:[?#]|$)/i.test(url.split("?")[0] || url)) return false
  try {
    const params = new URLSearchParams(window.location.search)
    return (
      params.get("extractSubs") === "1" ||
      localStorage.getItem("xt_vod_extract_subtitles") === "1"
    )
  } catch {
    return false
  }
}

function removeGeneratedTracks(video: HTMLVideoElement): void {
  for (const track of Array.from(video.querySelectorAll("track[data-xt-vod-subtitle]"))) {
    track.remove()
  }
}

function appendTrack(video: HTMLVideoElement, track: ExtractedSubtitleTrack, index: number): void {
  const node = document.createElement("track")
  node.kind = "subtitles"
  node.src = track.src
  node.label = track.label || track.language || `Subtitle ${index + 1}`
  if (track.language) node.srclang = track.language
  node.dataset.xtVodSubtitle = "1"
  if (index === 0) node.default = true
  video.appendChild(node)
}

export async function attachExtractedVodSubtitles(
  video: HTMLVideoElement | null | undefined,
  sourceUrl: string,
): Promise<number> {
  if (!video || !canExtractDevSubtitles(sourceUrl)) return 0

  try {
    removeGeneratedTracks(video)
    const headers = resolveMediaHeaders(sourceUrl)
    const response = await fetch(
      `${VOD_SUBTITLE_PATH}?url=${encodeURIComponent(sourceUrl)}`,
      {
        headers: devProxyFetchHeaders(headers),
      },
    )
    if (!response.ok) return 0
    const payload = await response.json() as { tracks?: ExtractedSubtitleTrack[] }
    const tracks = Array.isArray(payload.tracks) ? payload.tracks : []
    tracks.forEach((track, index) => appendTrack(video, track, index))
    if (tracks.length) {
      log.log("[xt:player] extracted VOD subtitles", tracks.length)
      video.dispatchEvent(new Event("loadedmetadata"))
    }
    return tracks.length
  } catch (error) {
    if (import.meta.env.DEV) {
      log.debug("[xt:player] VOD subtitle extraction skipped", error)
    }
    return 0
  }
}
