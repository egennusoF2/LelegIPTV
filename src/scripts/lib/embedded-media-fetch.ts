import { getUserAgent } from "@/scripts/lib/app-settings.js"
import {
  useDevStreamProxy,
  wrapStreamUrlForDev,
  devProxyFetchHeaders,
  preferHttpsStreamUrl,
  resolveEmbeddedStreamUrl,
  unwrapStreamProxyUrl,
  isIosEmbedded,
} from "@/scripts/lib/stream-proxy"
import { log } from "@/scripts/lib/log.js"

const isTauri =
  typeof window !== "undefined" &&
  (!!(window as any).__TAURI_INTERNALS__ || !!(window as any).__TAURI__)

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
  return isTauri
}

export function resolveMediaHeaders(url: string): Headers {
  const headers = new Headers()
  const ua = mediaFetchContext?.userAgent || getUserAgent()
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
  const headers = resolveMediaHeaders(targetUrl)
  const incoming = new Headers(initParams?.headers || {})
  incoming.forEach((value, key) => {
    headers.set(key, value)
  })

  const requestUrl = useDevStreamProxy()
    ? wrapStreamUrlForDev(targetUrl)
    : targetUrl
  const requestHeaders = useDevStreamProxy()
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
  const requestUrl = useDevStreamProxy()
    ? wrapStreamUrlForDev(url)
    : upstream
  if (useDevStreamProxy() && import.meta.env.DEV) {
    log.log("[xt:stream] hls xhr", requestUrl.slice(0, 140))
  }
  xhr.open("GET", requestUrl, true)
  applyProxyHeadersToXhr(xhr, upstream)
}

export { resolveEmbeddedStreamUrl }

/** hls.js: manifest + segments with UA/referer; dev proxy or Tauri HTTP in app builds. */
export async function createEmbeddedHlsConfig(): Promise<Record<string, unknown>> {
  const devProxy = useDevStreamProxy()
  const tauriMedia = shouldUseProviderFetchForMedia()
  const config: Record<string, unknown> = {
    // WKWebView on iOS: workers often break hls.js segment loading.
    enableWorker: !devProxy && !isIosEmbedded(),
    enableWebVTT: true,
    renderTextTracksNatively: false,
  }

  if (tauriMedia) {
    const { createHlsProviderFetchLoader } = await import(
      "@/scripts/lib/hls-provider-loader.js"
    )
    config.loader = createHlsProviderFetchLoader()
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
export async function createEmbeddedMpegtsConfig(): Promise<Record<string, unknown>> {
  const headers: Record<string, string> = {}
  const ua = mediaFetchContext?.userAgent || getUserAgent()
  if (ua) headers["User-Agent"] = ua
  const referer = mediaFetchContext?.referer
  if (referer) headers["Referer"] = referer

  const config: Record<string, unknown> = {
    enableWorker: true,
    enableStashBuffer: false,
    stashInitialSize: 128,
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
