import { log } from "@/scripts/lib/log.js"
import {
  useDevStreamProxy,
  wrapStreamUrlForDev,
  devProxyFetchHeaders,
  preferHttpsStreamUrl,
  isIptvMediaUrl,
} from "@/scripts/lib/stream-proxy"
import { getUserAgent } from "@/scripts/lib/app-settings.js"

let installed = false

/** Fallback: patch window.fetch for IPTV media URLs only (not player_api / xmltv). */
export function installDevStreamFetchPatch(): void {
  if (installed || typeof window === "undefined" || !useDevStreamProxy()) return
  installed = true

  const nativeFetch = window.fetch.bind(window)
  window.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof Request
          ? input.url
          : String(input)
    if (!isIptvMediaUrl(url)) {
      return nativeFetch(input, init)
    }
    const target = preferHttpsStreamUrl(url)
    const proxyUrl = wrapStreamUrlForDev(target)
    const headers = new Headers(init?.headers)
    const ua = getUserAgent()
    if (ua) headers.set("User-Agent", ua)
    try {
      headers.set("Referer", `${new URL(target).origin}/`)
    } catch {}
    log.log("[xt:stream] fetch patch", proxyUrl.slice(0, 120))
    return nativeFetch(proxyUrl, {
      ...init,
      headers: devProxyFetchHeaders(headers),
    })
  }) as typeof fetch

  log.log("[xt:stream] dev fetch patch installed (media URLs only)")
}
