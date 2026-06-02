/** Shared IPTV stream proxy logic (Cloudflare Pages Function). */

export const PROXY_PATH = "/__stream"

const IPTV_UA_HLS =
  "Mozilla/5.0 (Linux; Android 9; SM-G960F) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 IPTVSmartersPlayer/3.1.5"

const IPTV_UA_VOD = "VLC/3.0.20 LibVLC/3.0.20"

export function corsHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Range, X-XT-UA, X-XT-Referer",
    "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges",
    ...extra,
  }
}

function resolveUpstreamUserAgent(url: string): string {
  if (/\.m3u8(?:[?#]|$)/i.test(url) || /\/live\//i.test(url)) return IPTV_UA_HLS
  if (/\/(movie|series)\//i.test(url)) return IPTV_UA_VOD
  return IPTV_UA_VOD
}

function resolvePlaylistUrl(baseUrl: string, ref: string): string {
  try {
    return new URL(ref, baseUrl).href
  } catch {
    return ref
  }
}

function wrapUrlForStreamProxy(absoluteUrl: string): string {
  if (absoluteUrl.startsWith(`${PROXY_PATH}?`)) return absoluteUrl
  try {
    const parsed = new URL(absoluteUrl)
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return absoluteUrl
    const host = parsed.hostname
    if (host === "localhost" || host === "127.0.0.1" || host === "[::1]") {
      return absoluteUrl
    }
  } catch {
    return absoluteUrl
  }
  return `${PROXY_PATH}?url=${encodeURIComponent(absoluteUrl)}`
}

function rewriteM3u8Line(line: string, baseUrl: string): string {
  const trimmed = line.trim()
  if (!trimmed) return line
  if (trimmed.startsWith(PROXY_PATH)) return line

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

function rewriteM3u8Playlist(body: string, baseUrl: string): string {
  return body
    .split(/\r?\n/)
    .map((line) => rewriteM3u8Line(line, baseUrl))
    .join("\n")
}

function bodyLooksLikeM3u8(body: string): boolean {
  return body.includes("#EXTM3U") || body.includes("#EXT-X-")
}

function copyUpstreamHeaders(upstream: Response): Record<string, string> {
  const out: Record<string, string> = {}
  for (const key of ["content-type", "content-length", "content-range", "accept-ranges"]) {
    const value = upstream.headers.get(key)
    if (value) out[key] = value
  }
  return out
}

/** Handle GET/HEAD/OPTIONS for `/__stream?url=…`. */
export async function handleStreamRequest(request: Request): Promise<Response> {
  const requestUrl = new URL(request.url)
  const target = requestUrl.searchParams.get("url")

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() })
  }

  if (!target) {
    return new Response("missing url", { status: 400, headers: corsHeaders() })
  }

  const method = request.method === "HEAD" ? "HEAD" : "GET"
  const decoded = decodeURIComponent(target)
  const userAgent =
    request.headers.get("x-xt-ua") || resolveUpstreamUserAgent(decoded)
  let referer = request.headers.get("x-xt-referer") || ""
  if (!referer) {
    try {
      referer = `${new URL(decoded).origin}/`
    } catch {
      referer = ""
    }
  }

  const upstreamHeaders = new Headers({ "User-Agent": userAgent })
  if (referer) upstreamHeaders.set("Referer", referer)
  const range = request.headers.get("range")
  if (range) upstreamHeaders.set("Range", range)

  let upstream = await fetch(decoded, {
    method,
    headers: upstreamHeaders,
    redirect: "follow",
  })

  if (method === "HEAD" && !upstream.ok) {
    upstreamHeaders.set("Range", "bytes=0-0")
    upstream = await fetch(decoded, {
      method: "GET",
      headers: upstreamHeaders,
      redirect: "follow",
    })
  }

  if (method === "HEAD") {
    const headers = corsHeaders(copyUpstreamHeaders(upstream))
    if (upstream.status === 206) {
      headers["content-range"] = upstream.headers.get("content-range") || ""
      const totalMatch = headers["content-range"]?.match(/\/(\d+)$/)
      if (totalMatch) headers["content-length"] = totalMatch[1]
      return new Response(null, { status: 200, headers })
    }
    return new Response(null, { status: upstream.status, headers })
  }

  const contentType = upstream.headers.get("content-type") || ""
  const urlSuggestsM3u8 = /\.m3u8(?:[?#]|$)/i.test(decoded)
  const mightBeM3u8 =
    urlSuggestsM3u8 || /mpegurl|m3u8|application\/vnd\.apple/i.test(contentType)

  if (mightBeM3u8 && upstream.ok) {
    const raw = await upstream.text()
    if (bodyLooksLikeM3u8(raw)) {
      const finalUrl = upstream.url || decoded
      const rewritten = rewriteM3u8Playlist(raw, finalUrl)
      return new Response(rewritten, {
        status: 200,
        headers: corsHeaders({
          "content-type": "application/vnd.apple.mpegurl; charset=utf-8",
        }),
      })
    }
    return new Response(raw, {
      status: upstream.status,
      headers: corsHeaders(copyUpstreamHeaders(upstream)),
    })
  }

  return new Response(upstream.body, {
    status: upstream.status,
    headers: corsHeaders(copyUpstreamHeaders(upstream)),
  })
}
