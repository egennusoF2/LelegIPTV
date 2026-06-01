/** Rewrite HLS playlist URLs so the browser always fetches via the dev stream proxy. */

import {
  STREAM_PROXY_PATH,
  unwrapStreamProxyUrl,
  isStreamProxyUrl,
  preferHttpsStreamUrl,
} from "./stream-proxy.ts"

export function resolvePlaylistUrl(baseUrl: string, ref: string): string {
  try {
    return new URL(ref, baseUrl).href
  } catch {
    return ref
  }
}

export function wrapUrlForStreamProxy(absoluteUrl: string): string {
  if (absoluteUrl.startsWith(STREAM_PROXY_PATH + "?")) return absoluteUrl
  if (isStreamProxyUrl(absoluteUrl)) {
    return absoluteUrl
  }
  const target = unwrapStreamProxyUrl(absoluteUrl)
  const normalized = preferHttpsStreamUrl(target)
  try {
    const parsed = new URL(normalized)
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return absoluteUrl
    const host = parsed.hostname
    if (
      host === "localhost" ||
      host === "127.0.0.1" ||
      host === "[::1]"
    ) {
      return absoluteUrl
    }
  } catch {
    return absoluteUrl
  }
  return `${STREAM_PROXY_PATH}?url=${encodeURIComponent(normalized)}`
}

export function rewriteM3u8Line(line: string, baseUrl: string): string {
  const trimmed = line.trim()
  if (!trimmed) return line
  if (trimmed.startsWith(STREAM_PROXY_PATH) || isStreamProxyUrl(trimmed)) {
    return line
  }

  let out = line.replace(/URI="([^"]+)"/gi, (_match, uri: string) => {
    const abs = resolvePlaylistUrl(baseUrl, uri)
    if (!/^https?:\/\//i.test(abs)) return `URI="${uri}"`
    return `URI="${wrapUrlForStreamProxy(abs)}"`
  })

  out = out.replace(/URI=(https?:\/\/[^\s,]+)/gi, (_match, uri: string) => {
    const abs = resolvePlaylistUrl(baseUrl, uri)
    return `URI=${wrapUrlForStreamProxy(abs)}`
  })

  const lineTrimmed = out.trim()
  if (!lineTrimmed.startsWith("#") && /^https?:\/\//i.test(lineTrimmed)) {
    return wrapUrlForStreamProxy(lineTrimmed)
  }
  if (!lineTrimmed.startsWith("#") && lineTrimmed.length > 0) {
    const abs = resolvePlaylistUrl(baseUrl, lineTrimmed)
    if (/^https?:\/\//i.test(abs)) return wrapUrlForStreamProxy(abs)
  }
  return out
}

export function rewriteM3u8Playlist(body: string, baseUrl: string): string {
  return body
    .split(/\r?\n/)
    .map((line) => rewriteM3u8Line(line, baseUrl))
    .join("\n")
}

export function looksLikeM3u8(
  contentType: string | null | undefined,
  targetUrl: string,
  bodyPreview?: string,
): boolean {
  if (/\.m3u8(?:[?#]|$)/i.test(targetUrl)) return true
  if (contentType && /mpegurl|m3u8|application\/vnd\.apple/i.test(contentType)) {
    return true
  }
  if (bodyPreview?.includes("#EXTM3U")) return true
  return false
}
