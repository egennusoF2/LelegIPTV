import { providerFetch } from "@/scripts/lib/provider-fetch.js"
import {
  preferHttpsStreamUrl,
  unwrapStreamProxyUrl,
} from "@/scripts/lib/stream-proxy"
import { resolveMediaHeaders } from "@/scripts/lib/embedded-media-fetch.js"

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
  const targetUrl = preferHttpsStreamUrl(unwrapStreamProxyUrl(context.url))
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

export function createHlsProviderFetchLoader() {
  return class HlsProviderFetchLoader {
    constructor() {
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
      const timeoutMs =
        config?.loadPolicy?.maxTimeToFirstByteMs ||
        config?.timeout ||
        20000

      if (this.controller && timeoutMs > 0) {
        this.timeout = setTimeout(() => {
          this.abort()
          callbacks.onTimeout?.(this.stats, context, null)
        }, timeoutMs)
      }

      providerFetch(targetUrl, {
        method: "GET",
        headers,
        signal: this.controller?.signal,
        forceTauri: true,
      })
        .then(async (response) => {
          if (this.timeout) clearTimeout(this.timeout)
          this.timeout = null
          this.stats.loading.first = now()
          const total = Number(response.headers?.get?.("content-length") || 0)
          this.stats.total = Number.isFinite(total) ? total : 0

          if (!response.ok && response.status !== 206) {
            callbacks.onError?.(
              { code: response.status || 0, text: response.statusText || "HTTP error" },
              context,
              response,
              this.stats,
            )
            return
          }

          const data =
            context.responseType === "arraybuffer"
              ? await response.arrayBuffer()
              : await response.text()
          this.stats.loaded =
            data instanceof ArrayBuffer ? data.byteLength : String(data).length
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
