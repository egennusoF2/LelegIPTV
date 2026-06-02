/** VOD helpers: HLS sibling URLs and light reachability probes. */

import { log, redactUrl } from "@/scripts/lib/log.js"
import {
  useDevStreamProxy,
  wrapStreamUrlForDev,
  devProxyFetchHeaders,
  isAppleEmbedded,
  isTauriEmbedded,
  preferPlainHttpForXtreamMedia,
} from "@/scripts/lib/stream-proxy"

const PROBE_MS = 5000
/** Master playlists often declare EXT-X-MEDIA after the first variants. */
const PROBE_BYTES = 16_384
const OFFLINE_FALLBACK_RE = /\b(TS_OFFLINE|offline|demo|placeholder)\b/i

interface HlsProbeResult {
  reachable: boolean
  url: string
  mediaLines: number
  subtitleLines: number
  audioLines: number
  /** Master playlist with variant renditions (needed for alternate tracks). */
  masterPlaylist: boolean
  /** Panel rejected HLS for this path (401/403) — skip further probes. */
  authDenied?: boolean
}

/** Paths where HLS was already rejected; avoids repeated 401 noise in console. */
const hlsDeniedPathKeys = new Set<string>()

export function vodStreamPathKey(url: string): string {
  try {
    return new URL(url).pathname.replace(/\.[a-z0-9]+$/i, "")
  } catch {
    return url.split("?")[0] || url
  }
}

export function isVodHlsDenied(url: string): boolean {
  return hlsDeniedPathKeys.has(vodStreamPathKey(url))
}

function scoreHlsProbe(probe: HlsProbeResult): number {
  return (
    probe.audioLines * 200 +
    probe.subtitleLines * 200 +
    probe.mediaLines * 10 +
    (probe.masterPlaylist ? 80 : 0)
  )
}

function emitVodChoice(reason: string, originalUrl: string, selectedUrl: string): void {
  try {
    document.dispatchEvent(
      new CustomEvent("xt:vod-source-choice", {
        detail: {
          reason,
          originalUrl: redactUrl(originalUrl),
          selectedUrl: redactUrl(selectedUrl),
          changed: originalUrl !== selectedUrl,
        },
      }),
    )
  } catch {}
}

/** Same Xtream path with `.m3u8` instead of `.mkv` / `.mp4` (multi-track HLS). */
function alignSiblingScheme(containerUrl: string, siblingUrl: string): string {
  try {
    const container = new URL(containerUrl)
    const sibling = new URL(siblingUrl)
    sibling.protocol = container.protocol
    sibling.port = container.port
    return sibling.href
  } catch {
    return siblingUrl
  }
}

function toSiblingUrl(url: string, ext: "m3u8" | "mp4" | "mkv"): string | null {
  if (!url) return null
  const stripped = url.split("?")[0] ?? ""
  if (new RegExp(`\\.${ext}$`, "i").test(stripped)) return null
  const sibling = url.replace(/\.(mkv|mp4|avi|ts)(\?|#|$)/i, `.${ext}$2`)
  if (sibling === url) return null
  return alignSiblingScheme(url, sibling)
}

function forceScheme(url: string, protocol: "http:" | "https:"): string | null {
  try {
    const parsed = new URL(url)
    parsed.protocol = protocol
    if (protocol === "http:" && parsed.port === "443") parsed.port = ""
    if (protocol === "https:" && parsed.port === "80") parsed.port = ""
    return parsed.href
  } catch {
    return null
  }
}

function uniqueUrls(urls: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const url of urls) {
    if (!url || seen.has(url)) continue
    seen.add(url)
    out.push(url)
  }
  return out
}

export function looksLikeOfflineFallback(value: string): boolean {
  return OFFLINE_FALLBACK_RE.test(value)
}

function hlsSiblingCandidates(originalUrl: string, normalizedUrl: string): string[] {
  const primary = toHlsSiblingUrl(normalizedUrl) || toHlsSiblingUrl(originalUrl)
  if (!primary) return []
  const preferred = preferPlainHttpForXtreamMedia(primary)
  const altScheme =
    preferred.startsWith("http:") && !preferred.startsWith("https:")
      ? forceScheme(preferred, "https:")
      : preferred.startsWith("https:")
        ? forceScheme(preferred, "http:")
        : null
  return uniqueUrls([preferred, primary !== preferred ? primary : null, altScheme])
}

export function toHlsSiblingUrl(url: string): string | null {
  return toSiblingUrl(url, "m3u8")
}

export function toMp4SiblingUrl(url: string): string | null {
  return toSiblingUrl(url, "mp4")
}

export function toMkvSiblingUrl(url: string): string | null {
  return toSiblingUrl(url, "mkv")
}

/** Xtream VOD paths usually expose an `.m3u8` next to the container file. */
export function isXtreamVodContainerUrl(url: string): boolean {
  if (!url) return false
  try {
    const path = new URL(url).pathname.toLowerCase()
    return (
      /\/(movie|series)\/[^/]+\/[^/]+\/\d+\.(mkv|mp4|avi|ts)$/i.test(path) ||
      /\/(movie|series)\/[^/]+\/[^/]+\/[^/]+\.(mkv|mp4|avi|ts)$/i.test(path)
    )
  } catch {
    return /\/(movie|series)\//i.test(url) && /\.(mkv|mp4|avi|ts)(\?|#|$)/i.test(url)
  }
}

async function buildProbeHeaders(upstreamUrl: string): Promise<Headers> {
  const headers = new Headers()
  try {
    const { resolveMediaHeaders } = await import(
      "@/scripts/lib/embedded-media-fetch.js"
    )
    const media = resolveMediaHeaders(upstreamUrl)
    media.forEach((value, key) => headers.set(key, value))
  } catch {
    try {
      headers.set("Referer", `${new URL(upstreamUrl).origin}/`)
    } catch {}
  }
  if (useDevStreamProxy()) {
    const proxyHdrs = devProxyFetchHeaders(headers) as Record<string, string>
    for (const [key, value] of Object.entries(proxyHdrs)) {
      headers.set(key, value)
    }
  }
  return headers
}

async function probeReachable(
  url: string,
  alternateUserAgent?: string,
): Promise<HlsProbeResult> {
  const failed = (authDenied = false): HlsProbeResult => ({
    reachable: false,
    url,
    mediaLines: 0,
    subtitleLines: 0,
    audioLines: 0,
    masterPlaylist: false,
    authDenied,
  })
  const controller =
    typeof AbortController !== "undefined" ? new AbortController() : null
  const timer = controller ? setTimeout(() => controller.abort(), PROBE_MS) : null
  try {
    let target = url
    if (useDevStreamProxy()) {
      target = wrapStreamUrlForDev(url)
    }
    const headers = await buildProbeHeaders(url)
    if (alternateUserAgent) {
      headers.set("User-Agent", alternateUserAgent)
      if (useDevStreamProxy()) {
        headers.set("X-XT-UA", alternateUserAgent)
      }
    }
    headers.set("Range", "bytes=0-2047")
    const { providerFetch } = await import("@/scripts/lib/provider-fetch.js")
    // When the dev proxy is active, `target` is a relative /__stream URL that
    // the Tauri HTTP plugin (Rust) cannot resolve. Use native fetch instead.
    const response = await providerFetch(target, {
      method: "GET",
      headers,
      signal: controller?.signal,
      forceTauri: !useDevStreamProxy(),
    })
    if (response.status === 401 || response.status === 403) {
      try {
        response.body?.cancel?.()
      } catch {}
      return failed(true)
    }
    if (response.status === 551) {
      try {
        response.body?.cancel?.()
      } catch {}
      hlsDeniedPathKeys.add(vodStreamPathKey(url))
      if (import.meta.env.DEV) {
        log.debug(
          "[xt:player] VOD HLS unavailable (551); skip further probes",
          redactUrl(url).slice(0, 120),
        )
      }
      return failed(true)
    }
    if (response.status === 404 || response.status >= 500) {
      try {
        response.body?.cancel?.()
      } catch {}
      return failed()
    }

    const ct = (response.headers.get("content-type") || "").toLowerCase()
    if (
      response.ok ||
      response.status === 206 ||
      ct.includes("mpegurl") ||
      ct.includes("m3u8")
    ) {
      let snippet = ""
      try {
        const buf = await response.arrayBuffer()
        snippet = new TextDecoder().decode(buf.slice(0, PROBE_BYTES))
      } catch {}
      try {
        response.body?.cancel?.()
      } catch {}
      if (
        !snippet.includes("#EXTM3U") &&
        !snippet.includes("#EXT-X-") &&
        !(response.ok && ct.includes("mpegurl"))
      ) {
        return failed()
      }
      const mediaLines = snippet.match(/^#EXT-X-MEDIA:.*$/gim)?.length || 0
      const subtitleLines = snippet.match(/^#EXT-X-MEDIA:.*TYPE=SUBTITLES.*$/gim)?.length || 0
      const audioLines = snippet.match(/^#EXT-X-MEDIA:.*TYPE=AUDIO.*$/gim)?.length || 0
      const masterPlaylist = /#EXT-X-STREAM-INF/i.test(snippet)
      if (snippet.includes("#EXTM3U") || snippet.includes("#EXT-X-")) {
        return {
          reachable: true,
          url,
          mediaLines,
          subtitleLines,
          audioLines,
          masterPlaylist,
        }
      }
      if (response.ok && ct.includes("mpegurl")) {
        return {
          reachable: true,
          url,
          mediaLines,
          subtitleLines,
          audioLines,
          masterPlaylist,
        }
      }
    }
    try {
      response.body?.cancel?.()
    } catch {}
    return failed()
  } catch {
    return failed()
  } finally {
    if (timer) clearTimeout(timer)
  }
}

async function probeNativeMp4Playable(url: string): Promise<boolean> {
  const controller =
    typeof AbortController !== "undefined" ? new AbortController() : null
  const timer = controller ? setTimeout(() => controller.abort(), PROBE_MS) : null
  try {
    let target = url
    if (useDevStreamProxy()) {
      target = wrapStreamUrlForDev(url)
    }
    const headers = await buildProbeHeaders(url)
    headers.set("Range", "bytes=0-2047")
    const { providerFetch } = await import("@/scripts/lib/provider-fetch.js")
    const response = await providerFetch(target, {
      method: "GET",
      headers,
      signal: controller?.signal,
      forceTauri: !useDevStreamProxy(),
    })
    if (response.status === 401 || response.status === 403 || response.status === 404) {
      try {
        response.body?.cancel?.()
      } catch {}
      return false
    }
    if (response.ok || response.status === 206) {
      try {
        const finalUrl = (response as Response).url || ""
        if (looksLikeOfflineFallback(finalUrl)) {
          return false
        }
      } catch {}
      let snippet = ""
      try {
        const buf = await response.arrayBuffer()
        snippet = new TextDecoder("latin1").decode(buf.slice(0, PROBE_BYTES))
      } catch {}
      try {
        response.body?.cancel?.()
      } catch {}
      if (looksLikeOfflineFallback(snippet)) return false
      return snippet.includes("ftyp")
    }
    try {
      response.body?.cancel?.()
    } catch {}
    return false
  } catch {
    return false
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/** Panels that only publish a container file (no parallel `.m3u8` ladder). */
const CONTAINER_ONLY_EXTENSIONS = new Set(["mkv", "avi", "wmv", "flv"])

export function containerExtensionFromUrl(url: string): string {
  const match = (url.split("?")[0] ?? "").match(/\.([a-z0-9]+)$/i)
  return (match?.[1] ?? "").toLowerCase()
}

/**
 * Xtream `get_vod_info` often reports `container_extension: mkv` with no HLS URL.
 * Probing `.m3u8` then always 401 — Smarters Lite plays the MKV via redirect+token.
 */
export function shouldSkipVodHlsSibling(
  url: string,
  containerExtension?: string,
): boolean {
  const ext = (containerExtension || containerExtensionFromUrl(url)).toLowerCase()
  return CONTAINER_ONLY_EXTENSIONS.has(ext)
}

/** Series episodes are usually a single `.mp4`; sibling `.m3u8` often returns HTTP 551. */
export function isXtreamSeriesContainerUrl(url: string): boolean {
  if (!url) return false
  try {
    const path = new URL(url).pathname.toLowerCase()
    return /\/series\/[^/]+\/[^/]+\/\d+\.[a-z0-9]+$/i.test(path)
  } catch {
    return /\/series\//i.test(url) && /\.[a-z0-9]+(\?|#|$)/i.test(url)
  }
}

/** Skip HLS sibling probes (save time and avoid pointless proxy traffic). */
export function shouldSkipVodHlsProbe(
  url: string,
  containerExtension?: string,
): boolean {
  if (shouldSkipVodHlsSibling(url, containerExtension)) return true
  return isXtreamSeriesContainerUrl(url)
}

export interface PreferVodHlsOptions {
  /** Try `.m3u8` without probe (only when caller already verified it exists). */
  optimistic?: boolean
  /** From Xtream `movie_data.container_extension` when known. */
  containerExtension?: string
}

/**
 * When the panel serves both a file (.mkv/.mp4) and an HLS ladder (.m3u8),
 * prefer the ladder so hls.js can expose audio / subtitle tracks.
 * Default: probe first; on 401/404 keep the container file so playback still works.
 */
export async function preferVodHlsUrl(
  url: string,
  options: PreferVodHlsOptions = {},
): Promise<string> {
  const normalizedUrl = preferPlainHttpForXtreamMedia(url)
  const streamKey = vodStreamPathKey(normalizedUrl)

  if (shouldSkipVodHlsProbe(normalizedUrl, options.containerExtension)) {
    if (import.meta.env.DEV) {
      const reason = isXtreamSeriesContainerUrl(normalizedUrl)
        ? "series mp4/mkv"
        : containerExtensionFromUrl(normalizedUrl) || options.containerExtension
      log.log("[xt:player] skip HLS sibling probe", reason)
    }
    emitVodChoice(
      isXtreamSeriesContainerUrl(normalizedUrl) ? "series-container" : "container-only",
      url,
      normalizedUrl,
    )
    return normalizedUrl
  }

  const hlsCandidates = hlsSiblingCandidates(url, normalizedUrl)
  const mp4Sibling = toMp4SiblingUrl(normalizedUrl)
  if (hlsCandidates.length === 0 && !mp4Sibling) return url

  if (hlsDeniedPathKeys.has(streamKey)) {
    emitVodChoice("hls-denied-cache", url, normalizedUrl)
    return normalizedUrl
  }

  if (hlsCandidates[0] && options.optimistic) {
    const sibling = hlsCandidates[0]
    if (import.meta.env.DEV) {
      log.log("[xt:player] VOD using pre-verified HLS sibling", redactUrl(sibling).slice(0, 120))
    }
    emitVodChoice("hls-optimistic", url, sibling)
    return sibling
  }

  const preferWebTracks =
    typeof window !== "undefined" &&
    !isTauriEmbedded() &&
    isXtreamVodContainerUrl(normalizedUrl)

  let bestHls: HlsProbeResult | null = null
  let bestScore = -1
  let firstReachable: HlsProbeResult | null = null
  for (const candidate of hlsCandidates) {
    const probe = await probeReachable(candidate)
    if (probe.authDenied) {
      hlsDeniedPathKeys.add(streamKey)
      if (import.meta.env.DEV) {
        log.debug(
          "[xt:player] VOD HLS denied/unavailable; using container file",
          redactUrl(normalizedUrl).slice(0, 120),
        )
      }
      break
    }
    if (!probe.reachable) continue
    if (!firstReachable) firstReachable = probe
    const score = scoreHlsProbe(probe)
    if (!bestHls || score > bestScore) {
      bestHls = probe
      bestScore = score
    }
    if (probe.subtitleLines > 0 && probe.audioLines > 0) break
  }

  const chosen = preferWebTracks ? bestHls || firstReachable : bestHls
  if (chosen) {
    const sibling = chosen.url
    if (import.meta.env.DEV) {
      log.log("[xt:player] VOD HLS sibling verified", {
        url: redactUrl(sibling).slice(0, 120),
        mediaLines: chosen.mediaLines,
        audioLines: chosen.audioLines,
        subtitleLines: chosen.subtitleLines,
        masterPlaylist: chosen.masterPlaylist,
        preferWebTracks,
      })
    }
    emitVodChoice(
      chosen.audioLines > 0 || chosen.subtitleLines > 0
        ? "hls-tracks-verified"
        : chosen.masterPlaylist
          ? preferWebTracks
            ? "hls-web-master"
            : "hls-master-verified"
          : preferWebTracks
            ? "hls-web-verified"
            : "hls-verified",
      url,
      sibling,
    )
    return sibling
  }

  if (
    mp4Sibling &&
    mp4Sibling !== normalizedUrl &&
    isAppleEmbedded() &&
    /\.(mkv|avi|ts)(\?|#|$)/i.test(normalizedUrl.split("?")[0] ?? "")
  ) {
    const mp4Playable = await probeNativeMp4Playable(mp4Sibling)
    if (mp4Playable) {
      if (import.meta.env.DEV) {
        log.log("[xt:player] VOD MP4 sibling verified for Apple WebKit", redactUrl(mp4Sibling).slice(0, 120))
      }
      emitVodChoice("apple-mp4-verified", url, mp4Sibling)
      return mp4Sibling
    }
  }

  if (import.meta.env.DEV) {
    log.debug("[xt:player] VOD HLS sibling unavailable; using original", redactUrl(url).slice(0, 120))
  }

  emitVodChoice("original", url, normalizedUrl)
  return normalizedUrl
}
