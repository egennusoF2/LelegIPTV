#!/usr/bin/env node
/**
 * Stream proxy server — gira su Oracle Free Tier
 * Serve il proxy IPTV su http://localhost:PORT/__stream?url=...
 * Nginx fa da reverse proxy per il path /__stream
 */

import http from "node:http"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"
import { URL } from "node:url"

const PORT = parseInt(process.env.PROXY_PORT || "3001", 10)
const HOST = process.env.PROXY_HOST || "0.0.0.0"

const IPTV_UA_HLS =
  "Mozilla/5.0 (Linux; Android 9; SM-G960F) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 IPTVSmartersPlayer/3.1.5"
const IPTV_UA_VOD = "VLC/3.0.20 LibVLC/3.0.20"

function resolveUA(url) {
  if (/player_api\.php|xmltv\.php|get\.php/i.test(url)) return IPTV_UA_HLS
  if (/\.m3u8(?:[?#]|$)/i.test(url) || /\/live\//i.test(url)) return IPTV_UA_HLS
  if (/\/(movie|series)\//i.test(url)) return IPTV_UA_VOD
  return IPTV_UA_HLS
}

function corsHeaders(extra = {}) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Range, X-XT-UA, X-XT-Referer",
    "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges",
    ...extra,
  }
}

function resolvePlaylistUrl(base, ref) {
  try { return new URL(ref, base).href } catch { return ref }
}

function wrapUrl(abs) {
  try {
    const p = new URL(abs)
    if (p.hostname === "localhost" || p.hostname === "127.0.0.1") return abs
  } catch { return abs }
  return `/__stream?url=${encodeURIComponent(abs)}`
}

function rewriteLine(line, baseUrl) {
  const t = line.trim()
  if (!t || t.startsWith("/__stream")) return line
  let out = line.replace(/URI="([^"]+)"/gi, (_, uri) => {
    const abs = resolvePlaylistUrl(baseUrl, uri)
    return /^https?:\/\//i.test(abs) ? `URI="${wrapUrl(abs)}"` : `URI="${uri}"`
  })
  const lt = out.trim()
  if (!lt.startsWith("#") && /^https?:\/\//i.test(lt)) return wrapUrl(lt)
  if (!lt.startsWith("#") && lt.length > 0) {
    const abs = resolvePlaylistUrl(baseUrl, lt)
    if (/^https?:\/\//i.test(abs)) return wrapUrl(abs)
  }
  return out
}

function rewriteM3u8(body, baseUrl) {
  return body.split(/\r?\n/).map(l => rewriteLine(l, baseUrl)).join("\n")
}

function looksLikeM3u8(body) {
  return body.includes("#EXTM3U") || body.includes("#EXT-X-")
}

function copyUpstreamHeaders(upstream) {
  const out = {}
  for (const key of ["content-type", "content-length", "content-range", "accept-ranges"]) {
    const value = upstream.headers.get(key)
    if (value) out[key] = value
  }
  return out
}

async function fetchUpstream(url, init) {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 20000)
  try {
    return await fetch(url, {
      ...init,
      redirect: "follow",
      signal: controller.signal,
    })
  } finally {
    clearTimeout(timeout)
  }
}

async function handleRequest(req, res) {
  const reqUrl = new URL(req.url, `http://${req.headers.host}`)

  if (req.method === "OPTIONS") {
    res.writeHead(204, corsHeaders())
    res.end()
    return
  }

  if (reqUrl.pathname !== "/__stream") {
    res.writeHead(404)
    res.end("Not found")
    return
  }

  const target = reqUrl.searchParams.get("url")
  if (!target) {
    res.writeHead(400, corsHeaders())
    res.end("missing url")
    return
  }

  const decoded = decodeURIComponent(target)
  const method = req.method === "HEAD" ? "HEAD" : "GET"
  const ua = req.headers["x-xt-ua"] || resolveUA(decoded)
  let referer = req.headers["x-xt-referer"] || ""
  if (!referer) {
    try { referer = `${new URL(decoded).origin}/` } catch {}
  }

  const upHeaders = new Headers({ "User-Agent": ua })
  if (referer) upHeaders.set("Referer", referer)
  if (req.headers.range) upHeaders.set("Range", req.headers.range)

  try {
    let upstream = await fetchUpstream(decoded, { method, headers: upHeaders })

    if (method === "HEAD" && !upstream.ok) {
      upHeaders.set("Range", "bytes=0-0")
      upstream = await fetchUpstream(decoded, { method: "GET", headers: upHeaders })
    }

    if (method === "HEAD") {
      const headers = corsHeaders(copyUpstreamHeaders(upstream))
      if (upstream.status === 206) {
        headers["content-range"] = upstream.headers.get("content-range") || ""
        const totalMatch = headers["content-range"]?.match(/\/(\d+)$/)
        if (totalMatch) headers["content-length"] = totalMatch[1]
        res.writeHead(200, headers)
      } else {
        res.writeHead(upstream.status, headers)
      }
      res.end()
      return
    }

    const contentType = upstream.headers.get("content-type") || ""
    const urlSuggestsM3u8 = /\.m3u8(?:[?#]|$)/i.test(decoded)
    const mightBeM3u8 =
      urlSuggestsM3u8 || /mpegurl|m3u8|application\/vnd\.apple/i.test(contentType)

    if (mightBeM3u8 && upstream.ok) {
      const raw = await upstream.text()
      if (looksLikeM3u8(raw)) {
        const finalUrl = upstream.url || decoded
        const rewritten = rewriteM3u8(raw, finalUrl)
        const body = Buffer.from(rewritten, "utf8")
        res.writeHead(200, corsHeaders({
          "content-type": "application/vnd.apple.mpegurl; charset=utf-8",
          "content-length": String(body.length),
        }))
        res.end(body)
        return
      }
      res.writeHead(upstream.status, corsHeaders(copyUpstreamHeaders(upstream)))
      res.end(raw)
      return
    }

    const passHeaders = copyUpstreamHeaders(upstream)
    res.writeHead(upstream.status, corsHeaders(passHeaders))
    if (upstream.body) {
      await pipeline(Readable.fromWeb(upstream.body), res)
    } else {
      res.end()
    }
  } catch (err) {
    if (!res.headersSent) {
      res.writeHead(502, corsHeaders())
      res.end(`Upstream error: ${err.message}`)
    }
  }
}

const server = http.createServer((req, res) => {
  handleRequest(req, res).catch(err => {
    console.error("[proxy] unhandled:", err)
    if (!res.headersSent) {
      res.writeHead(500)
      res.end("Internal error")
    }
  })
})

server.listen(PORT, HOST, () => {
  console.log(`[proxy] Stream proxy attivo su http://${HOST}:${PORT}/__stream`)
})

process.on("SIGTERM", () => server.close())
process.on("SIGINT", () => server.close())
