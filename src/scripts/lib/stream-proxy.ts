export const STREAM_PROXY_PATH = "/__stream"

function bakedStreamProxyOrigin(): string {
  try {
    return typeof __XT_STREAM_PROXY_ORIGIN__ === "string"
      ? __XT_STREAM_PROXY_ORIGIN__
      : ""
  } catch {
    return ""
  }
}

function bakedWebStreamProxyEnabled(): boolean {
  try {
    return __XT_WEB_STREAM_PROXY__ === "true"
  } catch {
    return false
  }
}

/** Absolute origin for `/__stream` when the Tauri app cannot host the proxy locally (e.g. Pages deploy). */
export function streamProxyOrigin(): string {
  const fromEnv = String(
    import.meta.env.PUBLIC_STREAM_PROXY_ORIGIN || bakedStreamProxyOrigin() || "",
  ).trim()
  if (fromEnv) return fromEnv.replace(/\/+$/, "")
  if (typeof window !== "undefined") {
    try {
      return window.location.origin
    } catch {}
  }
  return ""
}

export function isStreamProxyFetchUrl(url: string): boolean {
  try {
    const parsed = new URL(String(url), streamProxyOrigin() || "http://127.0.0.1/")
    return (
      parsed.pathname === STREAM_PROXY_PATH ||
      parsed.pathname.endsWith(STREAM_PROXY_PATH)
    )
  } catch {
    return (
      url.includes(`${STREAM_PROXY_PATH}?`) ||
      url.includes(encodeURIComponent(STREAM_PROXY_PATH))
    )
  }
}

/** When true, `providerFetch` must use Tauri plugin-http (not WKWebView fetch). */
export function shouldForceTauriFetch(url: string): boolean {
  if (!isTauriEmbedded()) return false
  // xtproxy:// is a registered WKWebView custom scheme — the native webview
  // handles it directly via the Rust UriSchemeHandler.  Do NOT route through
  // Tauri's http plugin (which speaks plain http/https only).
  if (url.startsWith("xtproxy://")) return false
  // WKWebView fetch to the Rust loopback proxy always fails with "Load failed".
  if (isNativeMediaProxyUrl(url)) return true
  if (!useDevStreamProxy()) return true
  return false
}

/** VOD file playback (mkv/mp4): VLC enables Range/206 on many Xtream panels. */
export const IPTV_UA_VOD = "VLC/3.0.20 LibVLC/3.0.20"

/**
 * HLS manifests/segments: IPTV player UA — browser UA often gets 401/403.
 * @see tracce-audio-sottotitoli-web-implementazione.md §2.4
 */
export const IPTV_UA_HLS =
  "Mozilla/5.0 (Linux; Android 9; SM-G960F) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 IPTVSmartersPlayer/3.1.5"

/**
 * Upstream User-Agent for IPTV media URLs (proxy, hls.js, probes, ffmpeg).
 * Settings → Network UA applies to API/M3U/EPG only, not stream fetches.
 */
export function resolveUpstreamUserAgent(url: string): string {
  if (!url) return IPTV_UA_VOD
  const target = unwrapStreamProxyUrl(url)
  try {
    const path = new URL(target).pathname
    if (/\/(movie|series)\//i.test(path)) return IPTV_UA_VOD
    if (/\.m3u8(?:[?#]|$)/i.test(target)) return IPTV_UA_HLS
    if (/\/live\//i.test(path)) return IPTV_UA_HLS
  } catch {
    if (/\/(movie|series)\//i.test(target)) return IPTV_UA_VOD
    if (/\/live\//i.test(target)) return IPTV_UA_HLS
    if (/\.m3u8(?:[?#]|$)/i.test(target)) return IPTV_UA_HLS
  }
  return IPTV_UA_VOD
}

/** Tauri shell (desktop / Android / iOS) — not the static web build. */
export function isTauriEmbedded(): boolean {
  return (
    typeof window !== "undefined" &&
    (!!(window as any).__TAURI_INTERNALS__ || !!(window as any).__TAURI__)
  )
}

export function isIosEmbedded(): boolean {
  if (typeof document !== "undefined") {
    if (document.documentElement?.getAttribute("data-platform") === "ios") {
      return isTauriEmbedded()
    }
  }
  if (typeof navigator === "undefined") return false
  const ua = navigator.userAgent || ""
  if (isTauriEmbedded() && /\b(iPad|iPhone|iPod)\b/i.test(ua)) return true
  // WKWebView on device sometimes omits "iPhone" in UA; iOS touch + no Android/desktop hints.
  if (
    isTauriEmbedded() &&
    typeof navigator.maxTouchPoints === "number" &&
    navigator.maxTouchPoints > 1 &&
    !/Android/i.test(ua)
  ) {
    return true
  }
  return false
}

export function isAppleEmbedded(): boolean {
  if (!isTauriEmbedded() || typeof navigator === "undefined") return false
  const ua = navigator.userAgent || ""
  const platform = navigator.platform || ""
  return (
    /\b(iPad|iPhone|iPod)\b/i.test(ua) ||
    /\bMacintosh\b/i.test(ua) ||
    /^Mac/i.test(platform)
  )
}

/** One-line diagnostic for macOS logs (Settings → or LelegIPTV.log). */
export function logStreamRouting(): void {
  if (!isTauriEmbedded() || typeof window === "undefined") return
  void import("@/scripts/lib/log.js").then(({ log }) => {
    log.info("[xt:stream] routing", {
      viteProxy: useDevStreamProxy(),
      localRustProxy: useNativeStreamProxy(),
      proxyTransport: useNativeStreamProxy() ? "rust-invoke" : "http",
      origin: import.meta.env.DEV
        ? streamProxyOrigin()
        : useNativeStreamProxy()
          ? "127.0.0.1 (/__stream)"
          : "direct",
    })
  })
}

/** True when the browser should fetch IPTV media via same-origin `/__stream`. */
export function useDevStreamProxy(): boolean {
  if (typeof window === "undefined") return false
  // Vite dev / preview on localhost (same as `pnpm dev` in the browser).
  if (import.meta.env.DEV) return true
  if (isTauriEmbedded()) return false
  // Production web deploy (Cloudflare Pages / Oracle with /__stream).
  if (
    import.meta.env.PUBLIC_WEB_STREAM_PROXY === "true" ||
    bakedWebStreamProxyEnabled()
  ) {
    return true
  }
  try {
    const host = window.location?.hostname || ""
    if (host === "localhost" || host === "127.0.0.1" || host === "[::1]") return true
    // Oracle / bare-IP web deploy (no Cloudflare Pages hostname).
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return true
    if (/\.pages\.dev$/i.test(host)) return true
  } catch {
    return false
  }
  return false
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
  // Live paths are also served over plain HTTP on most Xtream panels;
  // upgrading to HTTPS causes silent connection failures and infinite retries.
  return /\/(movie|series|live)\//i.test(pathname)
}

/** Xtream media endpoints often advertise HTTPS but only stream reliably over HTTP. */
export function preferPlainHttpForXtreamMedia(url: string): string {
  if (!url) return url
  try {
    const parsed = new URL(url)
    if (parsed.protocol === "https:" && isXtreamVodPath(parsed.pathname)) {
      parsed.protocol = "http:"
      if (parsed.port === "443") parsed.port = ""
      return parsed.href
    }
  } catch {}
  return url
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

/** Wrap an already-probed media URL without changing http/https. */
export function wrapExactStreamUrlForDev(url: string): string {
  if (!useDevStreamProxy()) return url
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
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return url
    const host = parsed.hostname
    if (
      host === "localhost" ||
      host === "127.0.0.1" ||
      host === "[::1]"
    ) {
      return url
    }
    return `${STREAM_PROXY_PATH}?url=${encodeURIComponent(url)}`
  } catch {
    return url
  }
}

/** True when streams use the on-device Rust proxy (127.0.0.1/__stream), like Vite dev. */
export function useNativeStreamProxy(): boolean {
  if (!isTauriEmbedded()) return false
  // `pnpm tauri dev` loads the UI from localhost:4321 — Vite already serves /__stream.
  if (import.meta.env.DEV) return false
  return true
}

export function isNativeMediaProxyUrl(url: string): boolean {
  // xtproxy:// is the macOS custom scheme that bypasses WebKit mixed-content
  // blocking.  Every xtproxy:// URL routes through the Rust UriSchemeHandler
  // and is therefore a local proxy URL.
  if (url.startsWith("xtproxy://")) return true
  try {
    const parsed = new URL(url, "http://127.0.0.1")
    const host = parsed.hostname
    const path = parsed.pathname
    return (
      (host === "127.0.0.1" || host === "localhost") &&
      (
        path === "/stream" ||
        path === "/__stream" ||
        path === "/__vod_hls" ||
        path.startsWith("/__vod_hls/") ||
        path === "/__vod_remux" ||
        path === "/__vod_streams" ||
        path === "/__vod_subtitle" ||
        path === "/__transcode"
      )
    )
  } catch {
    return false
  }
}

/** Dev `/__stream`, packaged Tauri Rust proxy, or passthrough. */
export async function resolveStreamFetchUrl(url: string): Promise<string> {
  if (isNativeMediaProxyUrl(url)) return url
  const normalized = preferPlainHttpForXtreamMedia(
    preferHttpsStreamUrl(unwrapStreamProxyUrl(url)),
  )
  if (useDevStreamProxy()) return wrapStreamUrlForDev(normalized)
  if (useNativeStreamProxy()) return resolveNativeStreamProxyUrl(normalized)
  return normalized
}

export async function resolveNativeStreamProxyUrl(url: string): Promise<string> {
  if (!useNativeStreamProxy()) return url
  if (isNativeMediaProxyUrl(url)) return url
  const upstream = unwrapStreamProxyUrl(
    preferPlainHttpForXtreamMedia(preferHttpsStreamUrl(url)),
  )
  if (isNativeMediaProxyUrl(upstream)) return upstream
  try {
    const { invoke } = await import("@tauri-apps/api/core")
    let referer = ""
    try {
      referer = `${new URL(upstream).origin}/`
    } catch {}
    const proxied = await invoke<string>("media_proxy_url", {
      url: upstream,
      userAgent: resolveUpstreamUserAgent(upstream),
      referer: referer || undefined,
    })
    const { log } = await import("@/scripts/lib/log.js")
    log.log("[xt:stream] local proxy", proxied.slice(0, 120))
    return proxied
  } catch (error) {
    const { log } = await import("@/scripts/lib/log.js")
    log.error("[xt:stream] media_proxy_url failed; using direct URL", error)
    return url
  }
}

export async function resolveNativeStreamProxyUrlExact(url: string): Promise<string> {
  if (!useNativeStreamProxy()) return url
  if (isNativeMediaProxyUrl(url)) return url
  const upstream = unwrapStreamProxyUrl(url)
  if (isNativeMediaProxyUrl(upstream)) return upstream
  try {
    const { invoke } = await import("@tauri-apps/api/core")
    let referer = ""
    try {
      referer = `${new URL(upstream).origin}/`
    } catch {}
    const proxied = await invoke<string>("media_proxy_url", {
      url: upstream,
      userAgent: resolveUpstreamUserAgent(upstream),
      referer: referer || undefined,
    })
    const { log } = await import("@/scripts/lib/log.js")
    log.log("[xt:stream] local proxy exact", proxied.slice(0, 120))
    return proxied
  } catch (error) {
    const { log } = await import("@/scripts/lib/log.js")
    log.error("[xt:stream] media_proxy_url exact failed; using direct URL", error)
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

/** MKV/AVI (and dev MP4 VOD) probed via ffmpeg/ffprobe for embedded track menus. */
export function isContainerUrl(url: string): boolean {
  const path = (url.split("?")[0] ?? "").toLowerCase()
  if (/\.(mkv|avi)(\?|#|$)/i.test(path)) return true
  if (/\.mp4(\?|#|$)/i.test(path) && /\/(movie|series)\//i.test(url)) {
    return true
  }
  return false
}

const VOD_REMUX_PATH_SEGMENT = "/__vod_remux"
const VOD_HLS_PATH_SEGMENT = "/__vod_hls"
const TRANSCODE_PATH_SEGMENT = "/__transcode"

function unwrapVodGeneratedTarget(url: string): string {
  try {
    const parsed = new URL(url, "http://127.0.0.1/")
    const path = parsed.pathname
    if (
      path === VOD_REMUX_PATH_SEGMENT ||
      path.endsWith(VOD_REMUX_PATH_SEGMENT) ||
      path === VOD_HLS_PATH_SEGMENT ||
      path.endsWith(VOD_HLS_PATH_SEGMENT) ||
      path === TRANSCODE_PATH_SEGMENT ||
      path.endsWith(TRANSCODE_PATH_SEGMENT)
    ) {
      const inner = parsed.searchParams.get("url")
      if (inner) return decodeURIComponent(inner)
    }
  } catch {}
  return url
}

/** Same VOD file path (ignores host/query/proxy wrapper) — e.g. backup host or remux vs direct. */
export function vodAssetPathKey(url: string): string {
  if (!url) return ""
  let target = unwrapStreamProxyUrl(url)
  target = unwrapVodGeneratedTarget(target)
  try {
    return new URL(target).pathname.toLowerCase()
  } catch {
    return target.split("?")[0]?.toLowerCase() || target
  }
}

export function vodStreamPathsEquivalent(a: string, b: string): boolean {
  if (!a || !b) return a === b
  return vodAssetPathKey(a) === vodAssetPathKey(b)
}

/** Avoid pointless player reload when backup-domain resolve returns the same asset. */
export function streamUrlsEquivalent(a: string, b: string): boolean {
  if (!a || !b) return a === b
  if (a === b) return true
  const strip = (value: string) => {
    try {
      const parsed = new URL(value)
      return `${parsed.protocol}//${parsed.host}${parsed.pathname}`.toLowerCase()
    } catch {
      return value.split("?")[0]?.toLowerCase() || value
    }
  }
  return strip(a) === strip(b)
}

export function resolveEmbeddedStreamUrl(url: string): string {
  if (isNativeMediaProxyUrl(url)) return url
  const normalized = preferPlainHttpForXtreamMedia(preferHttpsStreamUrl(url))
  if (!useDevStreamProxy()) return normalized
  const wrapped = wrapStreamUrlForDev(normalized)
  // iOS dev: absolute same-origin URL so native HLS resolves /__stream segment refs correctly.
  if (typeof window !== "undefined" && isIosEmbedded()) {
    try {
      return new URL(wrapped, window.location.origin).href
    } catch {}
  }
  return wrapped
}

/** HLS playback URL for embedded players (dev proxy, native proxy, or direct). */
export async function resolveHlsPlaybackUrl(url: string): Promise<string> {
  if (isNativeMediaProxyUrl(url)) return url
  const upstream = unwrapStreamProxyUrl(url)
  const resolved = useNativeStreamProxy()
    ? await resolveNativeStreamProxyUrlExact(upstream)
    : wrapExactStreamUrlForDev(upstream)
  if (import.meta.env.DEV && isIosEmbedded()) {
    const { log } = await import("@/scripts/lib/log.js")
    log.log("[xt:stream] ios hls playback", {
      via: useNativeStreamProxy() ? "media_proxy" : "dev_proxy",
      url: resolved.slice(0, 140),
    })
  }
  return resolved
}

export function devProxyFetchHeaders(mediaHeaders: Headers): HeadersInit {
  const out: Record<string, string> = {}
  const ua = mediaHeaders.get("User-Agent")
  const referer = mediaHeaders.get("Referer")
  if (ua) out["X-XT-UA"] = ua
  if (referer) out["X-XT-Referer"] = referer
  return out
}

/** When false, ArtPlayer uses native <video src> for .m3u8. */
export function shouldUseHlsJsForM3u8(opts?: { live?: boolean }): boolean {
  if (isIosEmbedded()) {
    // WKWebView native HLS plays proxied TS segments; hls.js/MSE is unreliable on iOS.
    return false
  }
  if (isTauriEmbedded()) return true
  if (typeof navigator === "undefined") return true
  const ua = navigator.userAgent || ""
  const isIos = /\b(iPad|iPhone|iPod)\b/i.test(ua)
  const isSafari =
    /Safari/i.test(ua) &&
    !/(Chrome|Chromium|CriOS|FxiOS|Edg|OPR|Android)/i.test(ua)
  return !(isIos || isSafari)
}
