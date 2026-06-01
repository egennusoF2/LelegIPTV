/** VOD helpers: HLS sibling URLs and light reachability probes. */

import { log } from "@/scripts/lib/log.js"
import {
  useDevStreamProxy,
  wrapStreamUrlForDev,
  devProxyFetchHeaders,
  isAppleEmbedded,
} from "@/scripts/lib/stream-proxy"

const PROBE_MS = 5000
const PROBE_BYTES = 2048

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

export function toHlsSiblingUrl(url: string): string | null {
  if (!url) return null
  const stripped = url.split("?")[0] ?? ""
  if (/\.m3u8$/i.test(stripped)) return null
  const sibling = url.replace(/\.(mkv|mp4|avi|ts)(\?|#|$)/i, ".m3u8$2")
  return alignSiblingScheme(url, sibling)
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

async function probeReachable(url: string): Promise<boolean> {
  const controller =
    typeof AbortController !== "undefined" ? new AbortController() : null
  const timer = controller ? setTimeout(() => controller.abort(), PROBE_MS) : null
  try {
    let target = url
    if (useDevStreamProxy()) {
      target = wrapStreamUrlForDev(url)
    }
    const headers = await buildProbeHeaders(url)
    const { providerFetch } = await import("@/scripts/lib/provider-fetch.js")
    const response = await providerFetch(target, {
      method: "GET",
      headers,
      signal: controller?.signal,
    })
    if (response.status === 401 || response.status === 403 || response.status === 404) {
      try {
        response.body?.cancel?.()
      } catch {}
      return false
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
      if (snippet.includes("#EXTM3U") || snippet.includes("#EXT-X-")) return true
      if (response.ok && ct.includes("mpegurl")) return true
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

export interface PreferVodHlsOptions {
  /** Try `.m3u8` without probe (only when caller already verified it exists). */
  optimistic?: boolean
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
  const sibling = toHlsSiblingUrl(url)
  if (!sibling) return url

  if (options.optimistic === true) {
    if (import.meta.env.DEV) {
      log.log("[xt:player] VOD trying HLS sibling (optimistic)", sibling.slice(0, 120))
    }
    return sibling
  }

  if (await probeReachable(sibling)) {
    if (import.meta.env.DEV) {
      log.log("[xt:player] VOD using HLS sibling (probe ok)", sibling.slice(0, 120))
    }
    return sibling
  }

  // Apple WebKit cannot reliably play .mkv/.avi containers; try HLS anyway
  // for Xtream VOD on macOS/iOS apps even when the lightweight probe failed.
  if (
    isAppleEmbedded() &&
    isXtreamVodContainerUrl(url) &&
    /\.(mkv|avi)(\?|#|$)/i.test(url.split("?")[0] ?? "")
  ) {
    log.warn(
      "[xt:player] Apple WebKit: container unsupported, trying HLS sibling",
      sibling.slice(0, 120),
    )
    return sibling
  }

  if (import.meta.env.DEV) {
    log.log("[xt:player] VOD HLS sibling not reachable, using container", url.slice(0, 120))
  }
  return url
}
