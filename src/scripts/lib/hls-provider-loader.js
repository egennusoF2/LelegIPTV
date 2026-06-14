import { providerFetch } from "@/scripts/lib/provider-fetch.js"
import {
  preferHttpsStreamUrl,
  preferPlainHttpForXtreamMedia,
  unwrapStreamProxyUrl,
  shouldForceTauriFetch,
  wrapStreamUrlForDev,
  useDevStreamProxy,
  useNativeStreamProxy,
  isNativeMediaProxyUrl,
  resolveStreamFetchUrl,
} from "@/scripts/lib/stream-proxy"
import { resolveMediaHeaders } from "@/scripts/lib/embedded-media-fetch.js"

function isGeneratedVodHls(url) {
  return /\/__vod_hls(?:\/|[?#]|$)/i.test(String(url || ""))
}

function now() {
  return typeof performance !== "undefined" && performance.now
    ? performance.now()
    : Date.now()
}

function makeStats() {
  return {
    aborted: false,
    loaded: 0,
    retry: 0,
    total: 0,
    chunkCount: 0,
    bwEstimate: 0,
    loading: { start: 0, first: 0, end: 0 },
    parsing: { start: 0, end: 0 },
    buffering: { start: 0, first: 0, end: 0 },
  }
}

function mergeHeaders(context) {
  const targetUrl = preferPlainHttpForXtreamMedia(
    preferHttpsStreamUrl(unwrapStreamProxyUrl(context.url)),
  )
  const headers = resolveMediaHeaders(targetUrl)
  for (const [key, value] of Object.entries(context.headers || {})) {
    headers.set(key, value)
  }
  if (context.rangeStart != null || context.rangeEnd != null) {
    const start = context.rangeStart ?? 0
    const end = context.rangeEnd != null ? context.rangeEnd - 1 : ""
    headers.set("Range", `bytes=${start}-${end}`)
  }
  return { targetUrl, headers }
}

export function createHlsProviderFetchLoader(opts = {}) {
  const isLive = opts.live === true
  return class HlsProviderFetchLoader {
    constructor() {
      this.isLive = isLive
      this.context = null
      this.stats = makeStats()
      this.controller =
        typeof AbortController !== "undefined" ? new AbortController() : null
      this.timeout = null
    }

    destroy() {
      this.abort()
      this.context = null
    }

    abort() {
      this.stats.aborted = true
      if (this.timeout) clearTimeout(this.timeout)
      this.timeout = null
      try { this.controller?.abort() } catch {}
    }

    load(context, config, callbacks) {
      this.context = context
      this.stats.loading.start = now()
      const { targetUrl, headers } = mergeHeaders(context)
      const fetchUrl = useDevStreamProxy()
        ? wrapStreamUrlForDev(targetUrl)
        : isNativeMediaProxyUrl(context.url)
          ? context.url
          : targetUrl
      const timeoutMs =
        isGeneratedVodHls(context.url) || isGeneratedVodHls(fetchUrl)
          ? 300000
          : config?.loadPolicy?.maxTimeToFirstByteMs ||
            config?.timeout ||
            20000

      if (this.controller && timeoutMs > 0) {
        this.timeout = setTimeout(() => {
          this.abort()
          callbacks.onTimeout?.(this.stats, context, null)
        }, timeoutMs)
      }

      const loadUrl = async () => {
        if (useDevStreamProxy() || isNativeMediaProxyUrl(context.url)) {
          return fetchUrl
        }
        return resolveStreamFetchUrl(context.url)
      }

      loadUrl()
        .then(async (resolvedFetchUrl) => {
          const { providerFetch, providerFetchUpstream } = await import(
            "@/scripts/lib/provider-fetch.js"
          )
          const upstream = unwrapStreamProxyUrl(resolvedFetchUrl)
          const viaNativeProxy =
            useNativeStreamProxy() &&
            (isNativeMediaProxyUrl(resolvedFetchUrl) ||
              isNativeMediaProxyUrl(context.url))
          if (viaNativeProxy) {
            return providerFetchUpstream(upstream, {
              method: "GET",
              headers,
              signal: this.controller?.signal,
            })
          }
          return providerFetch(resolvedFetchUrl, {
            method: "GET",
            headers,
            signal: this.controller?.signal,
            forceTauri: shouldForceTauriFetch(resolvedFetchUrl),
          })
        })
        .then(async (response) => {
          if (this.timeout) clearTimeout(this.timeout)
          this.timeout = null
          this.stats.loading.first = now()
          const total = Number(response.headers?.get?.("content-length") || 0)
          this.stats.total = Number.isFinite(total) ? total : 0

          if (!response.ok && response.status !== 206) {
            if (this.isLive && response.status === 410) {
              try {
                document.dispatchEvent(
                  new CustomEvent("xt:hls-live-stale", {
                    detail: { url: targetUrl },
                  }),
                )
              } catch {}
            }
            callbacks.onError?.(
              { code: response.status || 0, text: response.statusText || "HTTP error" },
              context,
              response,
              this.stats,
            )
            return
          }

          let data =
            context.responseType === "arraybuffer"
              ? await response.arrayBuffer()
              : await response.text()
          if (
            typeof data === "string" &&
            (data.includes("#EXTM3U") || data.includes("#EXT-X-"))
          ) {
            const { sanitizeTvMasterPlaylistIfNeeded } = await import(
              "@/scripts/lib/hls-manifest-sanitize.ts"
            )
            const { trimLiveMediaPlaylist } = await import(
              "@/scripts/lib/hls-live-playlist-trim.ts"
            )
            data = sanitizeTvMasterPlaylistIfNeeded(data)
            if (this.isLive && !useNativeStreamProxy()) {
              data = trimLiveMediaPlaylist(data)
            }
          }
          const byteLen =
            data instanceof ArrayBuffer ? data.byteLength : String(data).length
          if (
            byteLen === 0 &&
            (response.ok || response.status === 410) &&
            context.responseType === "arraybuffer"
          ) {
            if (this.isLive) {
              try {
                document.dispatchEvent(
                  new CustomEvent("xt:hls-live-stale", {
                    detail: { url: targetUrl },
                  }),
                )
              } catch {}
            }
            callbacks.onError?.(
              { code: response.status || 410, text: "Empty or expired segment" },
              context,
              response,
              this.stats,
            )
            return
          }
          this.stats.loaded = byteLen
          this.stats.loading.end = now()
          callbacks.onSuccess?.(
            { url: targetUrl, data, code: response.status, text: response.statusText },
            this.stats,
            context,
            response,
          )
        })
        .catch((error) => {
          if (this.timeout) clearTimeout(this.timeout)
          this.timeout = null
          if (this.stats.aborted) return
          callbacks.onError?.(
            { code: 0, text: String(error?.message || error || "Network error") },
            context,
            null,
            this.stats,
          )
        })
    }
  }
}
