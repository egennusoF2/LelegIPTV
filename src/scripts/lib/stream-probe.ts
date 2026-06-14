import { providerFetch } from "@/scripts/lib/provider-fetch.js"

export type StreamKind = "hls" | "hls-vod" | "dash" | "ts" | "native" | "unknown"

const PROBE_CACHE_TTL_MS = 10 * 60 * 1000
const probeCache = new Map<string, { kind: StreamKind; expiresAt: number }>()

export function streamKindFromUrl(
  src: string,
  mime?: string | null,
): StreamKind | "unknown" {
  if (/\/__transcode(?:\?|$)/i.test(src)) return "ts"
  if (/\/__vod_hls(?:\/|[?#]|$)/i.test(src)) return "hls"
  if (/\.m3u8(\?|$)/i.test(src)) return "hls"
  if (/\.mpd(\?|$)/i.test(src)) return "dash"
  if (/\.ts(\?|$)/i.test(src)) return "ts"
  if (/\.(mp4|m4v|mkv|webm|mov|avi|m4a|mp3|aac|flac|ogg)(\?|$)/i.test(src)) {
    return "native"
  }
  if (/\/live\/[^/]+\/[^/]+\/\d+(\?|#|$)/i.test(src)) return "hls"

  const normalizedMime = (mime || "").toLowerCase()
  if (normalizedMime.includes("dash+xml")) return "dash"
  if (normalizedMime.includes("mpegurl") || normalizedMime.includes("m3u8")) return "hls"
  if (
    normalizedMime === "video/mp2t" ||
    normalizedMime === "video/mpeg" ||
    normalizedMime.includes("mpegts")
  ) {
    return "ts"
  }
  if (normalizedMime.startsWith("video/") || normalizedMime.startsWith("audio/")) {
    return "native"
  }
  return "unknown"
}

export function isVodM3u8(sample: string): boolean {
  const s = sample.toLowerCase()
  if (s.includes("#ext-x-playlist-type: vod") || s.includes("#ext-x-playlist-type:vod")) {
    return true
  }
  if (s.includes("#ext-x-playlist-type: event")) return true
  if (s.includes("#ext-x-endlist")) return true

  const sequence = s.match(/#ext-x-media-sequence:\s*(\d+)/)
  if (sequence && Number.parseInt(sequence[1] || "0", 10) > 1) return false

  const segments = (s.match(/#extinf/g) || []).length
  return segments > 30
}

export async function probeStreamKind(
  src: string,
  signal?: AbortSignal,
): Promise<StreamKind> {
  const hint = streamKindFromUrl(src)
  if (hint !== "unknown" && hint !== "hls") return hint

  let cacheKey = ""
  try {
    const parsed = new URL(src)
    cacheKey = hint === "hls" ? src : parsed.origin
  } catch {
    return hint === "unknown" ? "hls" : hint
  }

  const cached = probeCache.get(cacheKey)
  if (cached && Date.now() < cached.expiresAt) return cached.kind

  const controller = signal ? null : new AbortController()
  const timer = controller ? setTimeout(() => controller.abort(), 4000) : null
  try {
    const response = await providerFetch(src, {
      method: "GET",
      headers: { Range: "bytes=0-2047" },
      signal: signal || controller?.signal,
    })
    const contentType = response.headers.get("content-type")
    let kind = streamKindFromUrl(src, contentType)
    if (kind === "unknown") kind = "hls"

    if (kind === "hls") {
      try {
        const sample = await response.text()
        if (isVodM3u8(sample)) kind = "hls-vod"
      } catch {}
    } else {
      try {
        response.body?.cancel?.()
      } catch {}
    }

    probeCache.set(cacheKey, { kind, expiresAt: Date.now() + PROBE_CACHE_TTL_MS })
    return kind
  } catch {
    return hint === "unknown" ? "hls" : hint
  } finally {
    if (timer) clearTimeout(timer)
  }
}
