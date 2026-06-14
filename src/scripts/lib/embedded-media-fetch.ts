import { getUserAgent } from "@/scripts/lib/app-settings.js"
import {
  useDevStreamProxy,
  wrapStreamUrlForDev,
  devProxyFetchHeaders,
  preferHttpsStreamUrl,
  resolveEmbeddedStreamUrl,
  unwrapStreamProxyUrl,
  isIosEmbedded,
  isIptvMediaUrl,
  resolveUpstreamUserAgent,
} from "@/scripts/lib/stream-proxy"
import { log } from "@/scripts/lib/log.js"

function isTauriRuntime(): boolean {
  return (
    typeof window !== "undefined" &&
    (!!(window as any).__TAURI_INTERNALS__ || !!(window as any).__TAURI__)
  )
}

function isLoopbackMediaProxyUrl(url: string): boolean {
  try {
    const parsed = new URL(url)
    return (
      (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost") &&
      /^\/__(?:stream|transcode|vod_hls)\b/.test(parsed.pathname)
    )
  } catch {
    return false
  }
}

export interface EmbeddedMediaFetchContext {
  userAgent?: string | null
  referer?: string | null
}

let mediaFetchContext: EmbeddedMediaFetchContext | null = null

export function setEmbeddedMediaFetchContext(
  ctx: EmbeddedMediaFetchContext | null,
): void {
  mediaFetchContext = ctx
}

export function clearEmbeddedMediaFetchContext(): void {
  mediaFetchContext = null
}

export function shouldUseProviderFetchForMedia(): boolean {
  if (!isTauriRuntime()) return false
  // In Tauri dev mode the Vite proxy at /__stream is reachable from the WebView
  // (the app connects to localhost:4321). Route HLS through the proxy instead of
  // the Tauri HTTP plugin IPC — gives the same speed as the web browser version.
  if (useDevStreamProxy()) return false
  return true
}

export function resolveMediaHeaders(url: string): Headers {
  const headers = new Headers()
  const upstream = unwrapStreamProxyUrl(url)
  const ua = isIptvMediaUrl(upstream)
    ? resolveUpstreamUserAgent(upstream)
    : mediaFetchContext?.userAgent || getUserAgent()
  if (ua) headers.set("User-Agent", ua)
  let referer = mediaFetchContext?.referer || null
  if (!referer) {
    try {
      referer = `${new URL(url).origin}/`
    } catch {}
  }
  if (referer) headers.set("Referer", referer)
  return headers
}

function applyProxyHeadersToXhr(xhr: XMLHttpRequest, targetUrl: string): void {
  const headers = resolveMediaHeaders(targetUrl)
  const proxyHdrs = devProxyFetchHeaders(headers) as Record<string, string>
  for (const [key, value] of Object.entries(proxyHdrs)) {
    try {
      xhr.setRequestHeader(key, value)
    } catch {}
  }
}

/**
 * hls.js fetchSetup must return a Request (or Promise<Request>), NOT a Response.
 */
export function buildHlsStreamRequest(
  url: string,
  initParams?: RequestInit,
): Request {
  const targetUrl = preferHttpsStreamUrl(url)
  const loopbackProxy = isLoopbackMediaProxyUrl(targetUrl)
  const headers = resolveMediaHeaders(targetUrl)
  const incoming = new Headers(initParams?.headers || {})
  incoming.forEach((value, key) => {
    headers.set(key, value)
  })

  const requestUrl = useDevStreamProxy() && !loopbackProxy
    ? wrapStreamUrlForDev(targetUrl)
    : targetUrl
  const requestHeaders = useDevStreamProxy() && !loopbackProxy
    ? devProxyFetchHeaders(headers)
    : headers

  if (useDevStreamProxy() && import.meta.env.DEV) {
    log.log("[xt:stream] hls fetch", requestUrl.slice(0, 140))
  }

  return new Request(requestUrl, {
    method: initParams?.method || "GET",
    headers: requestHeaders,
    signal: initParams?.signal,
    credentials: initParams?.credentials,
    mode: initParams?.mode,
    cache: initParams?.cache,
    referrer: initParams?.referrer,
    referrerPolicy: initParams?.referrerPolicy,
  })
}

/** hls.js XHR loader (default in many builds): open via dev proxy before send. */
export function buildHlsXhrSetup(
  xhr: XMLHttpRequest,
  url: string,
): void {
  const upstream = preferHttpsStreamUrl(unwrapStreamProxyUrl(url))
  const loopbackProxy = isLoopbackMediaProxyUrl(url) || isLoopbackMediaProxyUrl(upstream)
  const requestUrl = useDevStreamProxy() && !loopbackProxy
    ? wrapStreamUrlForDev(url)
    : upstream
  if (useDevStreamProxy() && import.meta.env.DEV) {
    log.log("[xt:stream] hls xhr", requestUrl.slice(0, 140))
  }
  xhr.open("GET", requestUrl, true)
  if (!loopbackProxy) applyProxyHeadersToXhr(xhr, upstream)
}

export { resolveEmbeddedStreamUrl }

/** hls.js: manifest + segments with UA/referer; dev proxy or Tauri HTTP in app builds. */
export async function createEmbeddedHlsConfig(
  opts: { live?: boolean } = {},
): Promise<Record<string, unknown>> {
  const isLive = opts.live === true
  const devProxy = useDevStreamProxy()
  const tauriMedia = shouldUseProviderFetchForMedia()
  const config: Record<string, unknown> = {
    // WKWebView on iOS: workers often break hls.js segment loading.
    enableWorker: !devProxy && !isIosEmbedded(),
    enableWebVTT: true,
    enableIMSC1: true,
    enableCEA708Captions: true,
    renderTextTracksNatively: false,
    // Xtream panels: LL-HLS often pulls expired segments (200 + empty body).
    lowLatencyMode: false,
    startFragPrefetch: isLive,
    ...(isLive
      ? {
          liveStartIndex: -1,
          initialLiveManifestSize: 1,
          liveSyncDurationCount: tauriMedia ? 1 : 3,
          liveMaxLatencyDurationCount: tauriMedia ? 4 : 8,
          maxLiveSyncPlaybackRate: 1.5,
        }
      : {
          maxBufferLength: 60,
          maxMaxBufferLength: 120,
        }),
    backBufferLength: isLive ? 30 : 90,
  }

  if (tauriMedia) {
    const { createHlsProviderFetchLoader } = await import(
      "@/scripts/lib/hls-provider-loader.js"
    )
    config.loader = createHlsProviderFetchLoader({ live: isLive })
    return config
  }

  return {
    ...config,
    fetchSetup: (context: { url: string }, initParams: RequestInit) =>
      buildHlsStreamRequest(context.url, initParams),
    xhrSetup: (xhr: XMLHttpRequest, url: string) => {
      buildHlsXhrSetup(xhr, url)
    },
  }
}

/** mpegts.js player config: provider loader on Tauri; dev proxy in browser dev. */
export async function createEmbeddedMpegtsConfig(
  opts: { live?: boolean } = {},
): Promise<Record<string, unknown>> {
  const isLive = opts.live !== false
  const headers: Record<string, string> = {}
  const ua = mediaFetchContext?.userAgent || getUserAgent()
  if (ua) headers["User-Agent"] = ua
  const referer = mediaFetchContext?.referer
  if (referer) headers["Referer"] = referer

  const config: Record<string, unknown> = {
    // Keep mpegts.js on the main thread when a custom loader is in use. The
    // loader depends on app-side fetch bridges and local loopback streams that
    // are less reliable when initialized from the transmux worker in WKWebView.
    enableWorker: false,
    enableStashBuffer: !isLive,
    stashInitialSize: isLive ? 128 : 384,
    // VOD transcodes are served as one continuous loopback stream. mpegts.js
    // lazyLoad defaults to keeping ~3 minutes, then aborts the HTTP request;
    // aborting our loopback stream kills ffmpeg and makes long movies appear
    // truncated. Keep lazy loading only for true live streams.
    lazyLoad: isLive,
    autoCleanupSourceBuffer: isLive,
    autoCleanupMaxBackwardDuration: isLive ? 30 : 300,
    autoCleanupMinBackwardDuration: isLive ? 15 : 120,
    ...(Object.keys(headers).length ? { headers } : {}),
  }

  if (useDevStreamProxy()) {
    const { createMpegtsDevProxyLoader } = await import(
      "@/scripts/lib/mpegts-dev-proxy-loader.js"
    )
    config.customLoader = createMpegtsDevProxyLoader((targetUrl) =>
      resolveMediaHeaders(targetUrl),
    )
    return config
  }

  if (!shouldUseProviderFetchForMedia()) return config
  const { createMpegtsProviderFetchLoader } = await import(
    "@/scripts/lib/mpegts-provider-loader.js"
  )
  config.customLoader = createMpegtsProviderFetchLoader()
  return config
}
