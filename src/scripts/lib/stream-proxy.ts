export const STREAM_PROXY_PATH = "/__stream"

const isTauri =
  typeof window !== "undefined" &&
  (!!(window as any).__TAURI_INTERNALS__ || !!(window as any).__TAURI__)

/** Tauri shell (desktop / Android / iOS) — not the static web build. */
export function isTauriEmbedded(): boolean {
  return isTauri
}

export function isIosEmbedded(): boolean {
  if (typeof navigator === "undefined") return false
  return (
    isTauriEmbedded() && /\b(iPad|iPhone|iPod)\b/i.test(navigator.userAgent || "")
  )
}

export function isAppleEmbedded(): boolean {
  if (!isTauriEmbedded() || typeof navigator === "undefined") return false
  const ua = navigator.userAgent || ""
  const platform = navigator.platform || ""
  return (
    /\b(iPad|iPhone|iPod)\b/i.test(ua) ||
    /\bMacintosh\b/i.test(ua) ||
    /\bMac\b/i.test(platform)
  )
}

/** True when Astro/Vite dev server stream proxy should be used (browser @ localhost). */
export function useDevStreamProxy(): boolean {
  if (typeof window === "undefined") return false
  if (isTauri) return false
  if (import.meta.env.DEV) return true
  try {
    const host = window.location?.hostname || ""
    return host === "localhost" || host === "127.0.0.1" || host === "[::1]"
  } catch {
    return false
  }
}

/** True for raw IPv4/IPv6 CDN hosts (common in Xtream HLS playlists). */
export function isIpStreamHost(hostname: string): boolean {
  if (!hostname) return false
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(hostname)) return true
  if (hostname.startsWith("[") && hostname.endsWith("]")) return true
  return false
}

/** IPTV edge nodes on :8080 / :25461 often speak plain HTTP only. */
export function shouldUpgradeHttpToHttps(url: string): boolean {
  if (!url) return false
  try {
    const parsed = new URL(url)
    if (isIpStreamHost(parsed.hostname)) return false
    if (parsed.protocol !== "http:") return false
    const port = parsed.port || "80"
    return port === "80"
  } catch {
    return false
  }
}

/** Same URL with https→http when TLS on the CDN is missing or broken. */
export function httpFallbackStreamUrl(url: string): string | null {
  if (!url) return null
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== "https:") return null
    parsed.protocol = "http:"
    if (parsed.port === "443") parsed.port = ""
    return parsed.href
  } catch {
    return null
  }
}

/**
 * Pick a fetchable URL for IPTV media:
 * - hostname panels: http:80 → https
 * - raw IP CDNs: https:443 → http (no valid TLS on many shards)
 * - :8080 etc.: leave scheme as-is
 */
function isXtreamVodPath(pathname: string): boolean {
  return /\/(movie|series)\//i.test(pathname)
}

export function preferHttpsStreamUrl(url: string): string {
  if (!url) return url
  try {
    const parsed = new URL(url)
    // VOD URLs are often http-only; upgrading breaks auth on many panels.
    if (isXtreamVodPath(parsed.pathname)) return url
    if (
      isIpStreamHost(parsed.hostname) &&
      parsed.protocol === "https:" &&
      (!parsed.port || parsed.port === "443")
    ) {
      parsed.protocol = "http:"
      parsed.port = ""
      return parsed.href
    }
    if (shouldUpgradeHttpToHttps(url)) {
      parsed.protocol = "https:"
      return parsed.href
    }
  } catch {}
  return url
}

/** Strip nested `/__stream?url=` wrappers (playlist rewrite + xhrSetup). */
export function unwrapStreamProxyUrl(url: string): string {
  let current = url.trim()
  for (let depth = 0; depth < 6; depth++) {
    if (current.startsWith(STREAM_PROXY_PATH + "?")) {
      const inner = new URLSearchParams(current.slice(STREAM_PROXY_PATH.length)).get(
        "url",
      )
      if (!inner || inner === current) break
      current = decodeURIComponent(inner)
      continue
    }
    try {
      const parsed = new URL(current, "http://127.0.0.1/")
      if (
        parsed.pathname === STREAM_PROXY_PATH ||
        parsed.pathname.endsWith(STREAM_PROXY_PATH)
      ) {
        const inner = parsed.searchParams.get("url")
        if (!inner || inner === current) break
        current = decodeURIComponent(inner)
        continue
      }
    } catch {
      break
    }
    break
  }
  return current
}

export function isStreamProxyUrl(url: string): boolean {
  return (
    url.includes(`${STREAM_PROXY_PATH}?`) ||
    url.includes(encodeURIComponent(STREAM_PROXY_PATH))
  )
}

export function wrapStreamUrlForDev(url: string): string {
  if (!useDevStreamProxy()) return preferHttpsStreamUrl(url)
  if (url.startsWith(STREAM_PROXY_PATH + "?")) return url
  try {
    const parsedIncoming = new URL(url, "http://127.0.0.1/")
    if (
      parsedIncoming.pathname === STREAM_PROXY_PATH ||
      parsedIncoming.pathname.endsWith(STREAM_PROXY_PATH)
    ) {
      return url.startsWith(STREAM_PROXY_PATH)
        ? url
        : `${STREAM_PROXY_PATH}${parsedIncoming.search}`
    }
  } catch {}
  const target = unwrapStreamProxyUrl(url)
  try {
    const normalized = preferHttpsStreamUrl(target)
    const parsed = new URL(normalized)
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return normalized
    const host = parsed.hostname
    if (
      host === "localhost" ||
      host === "127.0.0.1" ||
      host === "[::1]"
    ) {
      return normalized
    }
    return `${STREAM_PROXY_PATH}?url=${encodeURIComponent(normalized)}`
  } catch {
    return url
  }
}

/** True for HLS/MPEG-TS media URLs (not player_api, xmltv, images). */
export function isIptvMediaUrl(url: string): boolean {
  try {
    const parsed = new URL(url)
    const path = parsed.pathname.toLowerCase()
    if (/\.(m3u8|ts|m4s|mp2t|aac|mp4|mkv|webm|mov|avi)(\?|#|$)/i.test(path)) return true
    if (/\/live\//i.test(path)) return true
    if (/\/movie\//i.test(path)) return true
    if (/\/series\//i.test(path)) return true
    if (/\/timeshift\//i.test(path)) return true
    if (/\/play\//i.test(path)) return true
    return false
  } catch {
    return false
  }
}

export function resolveEmbeddedStreamUrl(url: string): string {
  const normalized = preferHttpsStreamUrl(url)
  return useDevStreamProxy() ? wrapStreamUrlForDev(normalized) : normalized
}

export function devProxyFetchHeaders(mediaHeaders: Headers): HeadersInit {
  const out: Record<string, string> = {}
  const ua = mediaHeaders.get("User-Agent")
  const referer = mediaHeaders.get("Referer")
  if (ua) out["X-XT-UA"] = ua
  if (referer) out["X-XT-Referer"] = referer
  return out
}

/**
 * When false, ArtPlayer uses native <video src> for .m3u8 (Safari / iOS browser).
 * Apple WebKit (macOS/iOS app included) should stay native: it has HLS built in,
 * while hls.js/MSE is unavailable or fragile there. Other Tauri WebViews keep
 * hls.js, backed by a provider-fetch loader for CORS/header-sensitive streams.
 */
export function shouldUseHlsJsForM3u8(): boolean {
  if (isAppleEmbedded()) return false
  if (isTauriEmbedded()) return true
  if (typeof navigator === "undefined") return true
  const ua = navigator.userAgent || ""
  const isIos = /\b(iPad|iPhone|iPod)\b/i.test(ua)
  const isSafari =
    /Safari/i.test(ua) &&
    !/(Chrome|Chromium|CriOS|FxiOS|Edg|OPR|Android)/i.test(ua)
  return !(isIos || isSafari)
}
