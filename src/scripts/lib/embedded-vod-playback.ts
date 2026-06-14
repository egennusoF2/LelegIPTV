/** VOD helpers: HLS sibling URLs and light reachability probes. */

import { log, redactUrl } from "@/scripts/lib/log.js"
import {
  useDevStreamProxy,
  useNativeStreamProxy,
  wrapStreamUrlForDev,
  devProxyFetchHeaders,
  isAppleEmbedded,
  isTauriEmbedded,
  isIosEmbedded,
  preferPlainHttpForXtreamMedia,
  IPTV_UA_VOD,
  IPTV_UA_HLS,
  shouldForceTauriFetch,
  resolveStreamFetchUrl,
  streamUrlsEquivalent,
} from "@/scripts/lib/stream-proxy"

const PROBE_MS = 5000
const TAURI_VOD_HLS_PROBE_BUDGET_MS = 15_000
/** Master playlists often declare EXT-X-MEDIA after the first variants. */
const PROBE_BYTES = 16_384
const OFFLINE_FALLBACK_RE =
  /\b(TS_OFFLINE|offline|demo|placeholder|no[_-]?stream|sample|test[_-]?clip)\b/i

/** Text often baked into panel standby MP4s (Spanish/Italian/etc.). */
const VOD_PLACEHOLDER_TEXT_RE =
  /MOMENTOS|ESTAREMOS|EN UNOS|USTEDES|standby|attesa|presto disponib|momenti|be right back/i

/** Minimum full-file sizes — panels serve the same ~35s clip for every title. */
const MIN_MOVIE_BYTES = 5 * 1024 * 1024
const MIN_SERIES_BYTES = 3 * 1024 * 1024
const MIN_VOD_BYTES = 2 * 1024 * 1024

/** Shorter than this after `loadedmetadata` ⇒ likely a panel standby clip. */
export const VOD_PLACEHOLDER_MAX_MOVIE_SEC = 120
export const VOD_PLACEHOLDER_MAX_SERIES_SEC = 300

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

const WEBVIEW_NATIVE_VOD_EXTENSIONS = new Set(["mp4", "m3u8"])

/** Keep MP4/HLS after backup-host resolve would swap back to MKV (same VOD id). */
export function shouldPreserveVodPlaySrc(
  currentPlaySrc: string,
  resolvedSrc: string,
): boolean {
  if (!currentPlaySrc || !resolvedSrc) return false
  if (streamUrlsEquivalent(currentPlaySrc, resolvedSrc)) return true
  if (vodStreamPathKey(currentPlaySrc) !== vodStreamPathKey(resolvedSrc)) {
    return false
  }
  const currentExt = containerExtensionFromUrl(currentPlaySrc)
  const resolvedExt = containerExtensionFromUrl(resolvedSrc)
  return (
    WEBVIEW_NATIVE_VOD_EXTENSIONS.has(currentExt) &&
    !WEBVIEW_NATIVE_VOD_EXTENSIONS.has(resolvedExt)
  )
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

export function looksLikeVodPlaceholderSnippet(value: string): boolean {
  return VOD_PLACEHOLDER_TEXT_RE.test(value)
}

export function parseContentTotalBytes(response: Response): number | null {
  const range = response.headers.get("content-range") || ""
  const rangeMatch = range.match(/\/(\d+)\s*$/)
  if (rangeMatch) {
    const total = Number(rangeMatch[1])
    if (Number.isFinite(total) && total > 0) return total
  }
  // Partial range responses expose chunk length in Content-Length, not file size.
  if (response.status === 200) {
    const length = response.headers.get("content-length")
    if (length) {
      const total = Number(length)
      if (Number.isFinite(total) && total > 0) return total
    }
  }
  return null
}

export function vodContainerTooSmall(url: string, totalBytes: number): boolean {
  if (!Number.isFinite(totalBytes) || totalBytes <= 0) return false
  if (/\/movie\//i.test(url)) return totalBytes < MIN_MOVIE_BYTES
  if (/\/series\//i.test(url)) return totalBytes < MIN_SERIES_BYTES
  return totalBytes < MIN_VOD_BYTES
}

export function vodPlaceholderMaxDurationSec(url: string): number {
  if (/\/series\//i.test(url)) return VOD_PLACEHOLDER_MAX_SERIES_SEC
  return VOD_PLACEHOLDER_MAX_MOVIE_SEC
}

export function isLikelyVodPlaceholderDuration(
  url: string,
  durationSec: number,
): boolean {
  if (!Number.isFinite(durationSec) || durationSec <= 0) return false
  return durationSec < vodPlaceholderMaxDurationSec(url)
}

/** Read `mvhd` duration from an MP4 header buffer (moov is usually near the start on short clips). */
export function parseMp4DurationSec(buffer: ArrayBuffer): number | null {
  if (!buffer || buffer.byteLength < 32) return null
  const view = new DataView(buffer)
  const bytes = new Uint8Array(buffer)
  const end = buffer.byteLength

  const boxType = (at: number) =>
    String.fromCharCode(bytes[at]!, bytes[at + 1]!, bytes[at + 2]!, bytes[at + 3]!)

  const readMvhd = (payloadStart: number, payloadSize: number): number | null => {
    if (payloadSize < 20) return null
    const version = bytes[payloadStart]!
    if (version === 0) {
      const timescale = view.getUint32(payloadStart + 12)
      const duration = view.getUint32(payloadStart + 16)
      if (!timescale) return null
      return duration / timescale
    }
    if (version === 1 && payloadSize >= 32) {
      const timescale = view.getUint32(payloadStart + 20)
      const duration =
        view.getUint32(payloadStart + 24) * 2 ** 32 + view.getUint32(payloadStart + 28)
      if (!timescale) return null
      return duration / timescale
    }
    return null
  }

  const scan = (start: number, stop: number): number | null => {
    let offset = start
    while (offset + 8 <= stop) {
      let size = view.getUint32(offset)
      const type = boxType(offset + 4)
      let header = 8
      if (size === 1) {
        if (offset + 16 > stop) break
        size = Number(view.getBigUint64(offset + 8))
        header = 16
      }
      if (size < header || offset + size > stop) break
      const payloadStart = offset + header
      const payloadSize = size - header
      if (type === "mvhd") {
        const dur = readMvhd(payloadStart, payloadSize)
        if (dur != null && Number.isFinite(dur) && dur > 0) return dur
      }
      if (
        type === "moov" ||
        type === "trak" ||
        type === "mdia" ||
        type === "minf" ||
        type === "stbl"
      ) {
        const nested = scan(payloadStart, offset + size)
        if (nested != null) return nested
      }
      offset += size
    }
    return null
  }

  return scan(0, end)
}

/** Xtream asset id from `/movie/.../633617.mp4` or `/series/.../99123.mkv`. */
export function vodAssetIdFromUrl(url: string): string | null {
  try {
    const m = new URL(url).pathname.match(/\/(\d+)\.[a-z0-9]+$/i)
    return m?.[1] ?? null
  } catch {
    const m = String(url).match(/\/(\d+)\.[a-z0-9]+(?:[?#]|$)/i)
    return m?.[1] ?? null
  }
}

/** Reject panel redirects to a generic offline MP4 (same clip for every title). */
export function vodProbeMatchesRequestedAsset(
  requestUrl: string,
  responseUrl: string,
  snippet: string,
): boolean {
  if (looksLikeOfflineFallback(responseUrl) || looksLikeOfflineFallback(snippet)) {
    return false
  }
  if (looksLikeVodPlaceholderSnippet(snippet)) return false
  const assetId = vodAssetIdFromUrl(requestUrl)
  if (!assetId) return true
  if (responseUrl && !responseUrl.includes(assetId)) return false
  return true
}

function hlsSiblingCandidates(originalUrl: string, normalizedUrl: string): string[] {
  const originalSibling = toHlsSiblingUrl(originalUrl)
  const normalizedSibling = toHlsSiblingUrl(normalizedUrl)
  const primary = originalSibling || normalizedSibling
  if (!primary) return []
  const preferred = preferPlainHttpForXtreamMedia(primary)
  const altScheme =
    preferred.startsWith("http:") && !preferred.startsWith("https:")
      ? forceScheme(preferred, "https:")
      : preferred.startsWith("https:")
        ? forceScheme(preferred, "http:")
        : null
  return uniqueUrls([
    primary,
    normalizedSibling && normalizedSibling !== primary ? normalizedSibling : null,
    preferred !== primary ? preferred : null,
    altScheme,
  ])
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
  if (isVodHlsProbeUrl(upstreamUrl)) {
    headers.set("Referer", upstreamUrl)
  }
  if (useDevStreamProxy()) {
    const proxyHdrs = devProxyFetchHeaders(headers) as Record<string, string>
    for (const [key, value] of Object.entries(proxyHdrs)) {
      headers.set(key, value)
    }
  }
  return headers
}

function isVodHlsProbeUrl(url: string): boolean {
  return /\/(movie|series)\//i.test(url) && /\.m3u8(?:[?#]|$)/i.test(url)
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
    const isVodHls = isVodHlsProbeUrl(url)
    let target = url
    if (useDevStreamProxy()) {
      target = await resolveStreamFetchUrl(url)
    }
    const { providerFetch, providerFetchUpstream } = await import(
      "@/scripts/lib/provider-fetch.js"
    )
    const fetchProbe = async (probeHeaders: Headers) =>
      useNativeStreamProxy()
        ? await providerFetchUpstream(url, {
            method: "GET",
            headers: probeHeaders,
            signal: controller?.signal,
          })
        : await providerFetch(target, {
            method: "GET",
            headers: probeHeaders,
            signal: controller?.signal,
            forceTauri: shouldForceTauriFetch(target),
          })

    const uaAttempts = isVodHls
      ? uniqueUrls([
          alternateUserAgent || null,
          IPTV_UA_VOD,
          IPTV_UA_HLS,
        ]).filter(Boolean)
      : [alternateUserAgent || null]

    let response: Response | null = null
    let sawAuthFailure = false

    for (const ua of uaAttempts.length ? uaAttempts : [null]) {
      const headers = await buildProbeHeaders(url)
      if (ua) {
        headers.set("User-Agent", ua)
        if (useDevStreamProxy()) headers.set("X-XT-UA", ua)
      }
      if (!/\.m3u8(?:[?#]|$)/i.test(url)) {
        headers.set("Range", "bytes=0-2047")
      }
      const attempt = await fetchProbe(headers)
      if (attempt.status === 401 || attempt.status === 403) {
        sawAuthFailure = true
        try {
          attempt.body?.cancel?.()
        } catch {}
        continue
      }
      response = attempt
      break
    }

    if (!response) {
      return failed(sawAuthFailure)
    }

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

export async function probeNativeMp4Playable(url: string): Promise<boolean> {
  const controller =
    typeof AbortController !== "undefined" ? new AbortController() : null
  const timer = controller ? setTimeout(() => controller.abort(), PROBE_MS) : null
  try {
    let target = url
    if (useDevStreamProxy()) {
      target = await resolveStreamFetchUrl(url)
    }
    const headers = await buildProbeHeaders(url)
    headers.set("Range", "bytes=0-65535")
    const { providerFetch, providerFetchUpstream } = await import(
      "@/scripts/lib/provider-fetch.js"
    )
    const response = useNativeStreamProxy()
      ? await providerFetchUpstream(url, {
          method: "GET",
          headers,
          signal: controller?.signal,
        })
      : await providerFetch(target, {
          method: "GET",
          headers,
          signal: controller?.signal,
          forceTauri: shouldForceTauriFetch(target),
        })
    if (response.status === 401 || response.status === 403 || response.status === 404) {
      try {
        response.body?.cancel?.()
      } catch {}
      return false
    }
    if (response.ok || response.status === 206) {
      let finalUrl = ""
      try {
        finalUrl = (response as Response).url || ""
      } catch {}
      const ct = (response.headers.get("content-type") || "").toLowerCase()
      let snippet = ""
      let probeBuffer: ArrayBuffer | null = null
      try {
        probeBuffer = await response.arrayBuffer()
        snippet = new TextDecoder("latin1").decode(probeBuffer.slice(0, PROBE_BYTES))
      } catch {}
      try {
        response.body?.cancel?.()
      } catch {}
      const totalBytes = parseContentTotalBytes(response)
      if (totalBytes != null && vodContainerTooSmall(url, totalBytes)) {
        log.warn("[xt:player] VOD MP4 probe rejected (file too small)", {
          url: redactUrl(url).slice(0, 120),
          totalBytes,
        })
        return false
      }
      if (probeBuffer) {
        const headerDuration = parseMp4DurationSec(probeBuffer)
        if (
          headerDuration != null &&
          isLikelyVodPlaceholderDuration(url, headerDuration)
        ) {
          log.warn("[xt:player] VOD MP4 probe rejected (short mvhd duration)", {
            url: redactUrl(url).slice(0, 120),
            durationSec: headerDuration,
          })
          return false
        }
      }
      if (!vodProbeMatchesRequestedAsset(url, finalUrl, snippet)) {
        log.warn("[xt:player] VOD MP4 probe rejected (placeholder/offline redirect)", {
          url: redactUrl(url).slice(0, 120),
        })
        return false
      }
      if (snippet.includes("ftyp")) return true
      return false
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

export async function probeVodContainerReachable(url: string): Promise<boolean> {
  const controller =
    typeof AbortController !== "undefined" ? new AbortController() : null
  const timer = controller ? setTimeout(() => controller.abort(), PROBE_MS) : null
  try {
    let target = url
    if (useDevStreamProxy()) {
      target = await resolveStreamFetchUrl(url)
    }
    const headers = await buildProbeHeaders(url)
    headers.set("Range", "bytes=0-2047")
    const { providerFetch, providerFetchUpstream } = await import(
      "@/scripts/lib/provider-fetch.js"
    )
    const response = useNativeStreamProxy()
      ? await providerFetchUpstream(url, {
          method: "GET",
          headers,
          signal: controller?.signal,
        })
      : await providerFetch(target, {
          method: "GET",
          headers,
          signal: controller?.signal,
          forceTauri: shouldForceTauriFetch(target),
        })
    if (
      response.status === 401 ||
      response.status === 403 ||
      response.status === 404 ||
      response.status >= 500
    ) {
      try {
        response.body?.cancel?.()
      } catch {}
      return false
    }
    const reachable = response.ok || response.status === 206
    try {
      response.body?.cancel?.()
    } catch {}
    return reachable
  } catch {
    return false
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/**
 * Megacubo keeps the provider's real container candidate (including MKV) and
 * lets its proxy/FFmpeg layer handle compatibility. For external players we can
 * do the same: if the panel's MP4 is a short standby clip, try the MKV sibling.
 */
export async function resolveExternalVodPlayUrl(url: string): Promise<string> {
  const normalized = preferPlainHttpForXtreamMedia(url)
  if (!isXtreamVodContainerUrl(normalized)) return normalized
  const ext = containerExtensionFromUrl(normalized)
  if (ext !== "mp4") return normalized
  if (await probeNativeMp4Playable(normalized)) return normalized
  const mkvSibling = toMkvSiblingUrl(normalized)
  if (mkvSibling && (await probeVodContainerReachable(mkvSibling))) {
    log.info("[xt:player] VOD MP4 placeholder; using MKV for external player", {
      mp4: redactUrl(normalized).slice(0, 120),
      mkv: redactUrl(mkvSibling).slice(0, 120),
    })
    return mkvSibling
  }
  return normalized
}

export async function resolveExternalVodAfterPlaceholder(
  url: string,
): Promise<string | null> {
  const normalized = preferPlainHttpForXtreamMedia(url)
  if (!isXtreamVodContainerUrl(normalized)) return null
  const ext = containerExtensionFromUrl(normalized)
  const candidates = uniqueUrls([
    ext === "mkv" ? normalized : null,
    toMkvSiblingUrl(normalized),
  ])
  for (const candidate of candidates) {
    log.info("[xt:player] probing VOD external placeholder fallback", {
      src: redactUrl(candidate).slice(0, 120),
    })
    if (await probeVodContainerReachable(candidate)) {
      log.info("[xt:player] VOD placeholder fallback reachable", {
        src: redactUrl(candidate).slice(0, 120),
      })
      return candidate
    }
  }
  log.warn("[xt:player] no VOD external placeholder fallback reachable", {
    src: redactUrl(normalized).slice(0, 120),
  })
  return null
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
  // Desktop/mobile app: always try the `.m3u8` ladder (WebView cannot play MKV directly).
  if (isTauriEmbedded()) return false
  // Xtream VOD panels often expose the same asset as `.mkv` plus a sibling
  // `.m3u8` master playlist carrying audio/subtitle renditions.  Do not treat
  // MKV as "container-only" here; probing HLS is what exposes tracks.
  if (isXtreamVodContainerUrl(url)) return false
  const ext = (containerExtension || containerExtensionFromUrl(url)).toLowerCase()
  return CONTAINER_ONLY_EXTENSIONS.has(ext)
}

/** Series episodes are usually a single `.mp4`; sibling `.m3u8` often returns HTTP 551. */
export function isXtreamSeriesContainerUrl(url: string): boolean {
  if (isTauriEmbedded()) return false
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

async function resolveTauriVodHlsUrl(url: string): Promise<string | null> {
  if (!isTauriEmbedded() || !isXtreamVodContainerUrl(url)) return null
  // FFmpeg is not available on iOS; skip the local HLS transcoding proxy entirely.
  if (isIosEmbedded()) return null
  try {
    const { invoke } = await import("@tauri-apps/api/core")
    let referer = ""
    try {
      referer = `${new URL(url).origin}/`
    } catch {}
    const proxied = await invoke<string>("vod_hls_proxy_url", {
      url,
      userAgent: IPTV_UA_VOD,
      referer: referer || undefined,
      audioIndex: 0,
    })
    emitVodChoice("tauri-local-hls", url, proxied)
    return proxied
  } catch (error) {
    log.warn("[xt:player] VOD local HLS proxy unavailable", error)
    return null
  }
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
  const localHls = await resolveTauriVodHlsUrl(normalizedUrl)
  if (localHls) return localHls

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

  const preferWebTracks = isXtreamVodContainerUrl(normalizedUrl)

  let bestHls: HlsProbeResult | null = null
  let bestScore = -1
  let firstReachable: HlsProbeResult | null = null
  const probeBudgetMs = isTauriEmbedded()
    ? Math.max(TAURI_VOD_HLS_PROBE_BUDGET_MS, PROBE_MS * hlsCandidates.length)
    : PROBE_MS * hlsCandidates.length
  const probeDeadline = Date.now() + probeBudgetMs

  const probeOne = async (candidate: string): Promise<HlsProbeResult> => {
    if (Date.now() >= probeDeadline) {
      return {
        reachable: false,
        url: candidate,
        mediaLines: 0,
        subtitleLines: 0,
        audioLines: 0,
        masterPlaylist: false,
      }
    }
    return probeReachable(candidate)
  }

  const probes = await Promise.all(hlsCandidates.map((c) => probeOne(c)))
  let sawAuthDenied = false
  for (const probe of probes) {
    if (probe.authDenied) {
      sawAuthDenied = true
      continue
    }
    if (!probe.reachable) continue
    if (!firstReachable) firstReachable = probe
    const score = scoreHlsProbe(probe)
    if (!bestHls || score > bestScore) {
      bestHls = probe
      bestScore = score
    }
  }
  if (sawAuthDenied && !bestHls && !firstReachable) {
    hlsDeniedPathKeys.add(streamKey)
    const ext = (options.containerExtension || containerExtensionFromUrl(url)).toLowerCase()
    const containerFallback =
      (mp4Sibling && mp4Sibling !== normalizedUrl ? mp4Sibling : null) ||
      (ext && /\.m3u8(?:[?#]|$)/i.test(normalizedUrl)
        ? normalizedUrl.replace(/\.m3u8(\?|#|$)/i, `.${ext}$1`)
        : null)
    if (containerFallback && containerFallback !== normalizedUrl) {
      if (import.meta.env.DEV) {
        log.debug(
          "[xt:player] VOD HLS denied; using container file",
          redactUrl(containerFallback).slice(0, 120),
        )
      }
      emitVodChoice("hls-auth-denied-container", url, containerFallback)
      return preferPlainHttpForXtreamMedia(containerFallback)
    }
    if (import.meta.env.DEV) {
      log.debug(
        "[xt:player] VOD HLS denied/unavailable; using container file",
        redactUrl(normalizedUrl).slice(0, 120),
      )
    }
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

  const preferMp4Container =
    mp4Sibling &&
    mp4Sibling !== normalizedUrl &&
    isAppleEmbedded() &&
    (!isTauriEmbedded() || isIosEmbedded()) &&
    /\.(mkv|avi|ts|m3u8)(\?|#|$)/i.test(normalizedUrl.split("?")[0] ?? "")

  if (preferMp4Container) {
    const mp4Playable = await probeNativeMp4Playable(mp4Sibling)
    if (mp4Playable) {
      if (import.meta.env.DEV) {
        log.log("[xt:player] VOD MP4 sibling verified", redactUrl(mp4Sibling).slice(0, 120))
      }
      emitVodChoice(isTauriEmbedded() ? "tauri-mp4-verified" : "apple-mp4-verified", url, mp4Sibling)
      return mp4Sibling
    }
  }

  if (import.meta.env.DEV) {
    log.debug("[xt:player] VOD HLS sibling unavailable; using original", redactUrl(url).slice(0, 120))
  }

  emitVodChoice("original", url, normalizedUrl)
  return normalizedUrl
}

/** True when this container URL is safe to assign to `<video>` on Tauri.
 *
 * WKWebView (AVFoundation) does NOT support MKV, AVI, WMV or FLV — they are remuxed
 * by the FFmpeg transcode endpoint before reaching the player.  Only MP4 with a valid
 * non-placeholder header is allowed through directly.
 */
export async function canPlayVodNativeOnTauri(url: string): Promise<boolean> {
  if (!isTauriEmbedded() || !url) return true
  const ext = containerExtensionFromUrl(url)
  if (CONTAINER_ONLY_EXTENSIONS.has(ext)) return false
  if (ext === "mp4") return probeNativeMp4Playable(url)
  return ext !== "mkv" && ext !== "avi"
}

let vodPlaceholderGuardSeq = 0

/** Runtime guard: panels can serve a valid MP4 header with a ~35s standby clip. */
export function wireVodPlaceholderGuard(
  video: HTMLVideoElement | null | undefined,
  upstreamUrl: string,
  onPlaceholder?: () => void | Promise<void>,
): () => void {
  if (!video || !upstreamUrl) return () => {}
  const guardId = ++vodPlaceholderGuardSeq
  const handler = () => {
    if (guardId !== vodPlaceholderGuardSeq) return
    const dur = video.duration
    if (!isLikelyVodPlaceholderDuration(upstreamUrl, dur)) return
    log.warn("[xt:player] VOD placeholder detected (duration)", {
      url: redactUrl(upstreamUrl).slice(0, 120),
      durationSec: dur,
    })
    try {
      video.pause()
    } catch {}
    video.removeAttribute("src")
    try {
      video.load()
    } catch {}
    onPlaceholder?.()
  }
  video.addEventListener("loadedmetadata", handler, { once: true })
  return () => {
    vodPlaceholderGuardSeq++
    video.removeEventListener("loadedmetadata", handler)
  }
}
