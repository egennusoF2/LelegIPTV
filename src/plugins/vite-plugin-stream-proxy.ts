/**
 * Dev-only reverse proxy for IPTV stream URLs (HLS segments, MPEG-TS, manifests).
 * Browsers cannot set Referer reliably and block cross-origin redirects; Node fetch can.
 */
import type { Plugin, ViteDevServer } from "vite"
import {
  looksLikeM3u8,
  rewriteM3u8Playlist,
} from "../scripts/lib/m3u8-proxy-rewrite.ts"
import {
  preferHttpsStreamUrl,
  httpFallbackStreamUrl,
} from "../scripts/lib/stream-proxy.ts"

const PROXY_PATH = "/__stream"

const DEFAULT_UA =
  "VLC/3.0.20 LibVLC/3.0.20"

function isAllowedTarget(url: string): boolean {
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false
    const host = parsed.hostname
    if (
      host === "localhost" ||
      host === "127.0.0.1" ||
      host === "[::1]" ||
      host.endsWith(".local")
    ) {
      return false
    }
    return true
  } catch {
    return false
  }
}

async function proxyHandler(
  req: import("http").IncomingMessage,
  res: import("http").ServerResponse,
): Promise<void> {
  const requestUrl = req.url || ""
  const qIndex = requestUrl.indexOf("?")
  const search = qIndex >= 0 ? requestUrl.slice(qIndex) : ""
  const params = new URLSearchParams(search)
  let target = params.get("url")
  if (target) {
    target = preferHttpsStreamUrl(target)
  }
  if (!target || !isAllowedTarget(target)) {
    res.statusCode = 400
    res.setHeader("Content-Type", "text/plain; charset=utf-8")
    res.end("Invalid or missing stream url")
    return
  }

  const ua =
    (typeof req.headers["x-xt-ua"] === "string" && req.headers["x-xt-ua"]) ||
    DEFAULT_UA
  let referer =
    (typeof req.headers["x-xt-referer"] === "string" &&
      req.headers["x-xt-referer"]) ||
    ""
  if (!referer) {
    try {
      referer = `${new URL(target).origin}/`
    } catch {}
  }

  const method = req.method === "HEAD" ? "HEAD" : "GET"
  const fetchHeaders = {
    "User-Agent": ua,
    ...(referer ? { Referer: referer } : {}),
  }
  console.log("[xt:stream-proxy]", req.method, target.slice(0, 120))

  async function fetchUpstream(url: string) {
    return fetch(url, {
      method,
      headers: fetchHeaders,
      redirect: "follow",
    })
  }

  try {
    let upstream = await fetchUpstream(target)
    if (
      !upstream.ok &&
      upstream.status >= 500 &&
      target.startsWith("https://")
    ) {
      const fallback = httpFallbackStreamUrl(target)
      if (fallback) {
        console.log("[xt:stream-proxy] retry http", fallback.slice(0, 120))
        upstream = await fetchUpstream(fallback)
      }
    }

    res.statusCode = upstream.status
    res.setHeader("Access-Control-Allow-Origin", "*")
    res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
    res.setHeader(
      "Access-Control-Allow-Headers",
      "Content-Type, X-XT-UA, X-XT-Referer",
    )

    const contentType = upstream.headers.get("content-type")

    if (method === "HEAD") {
      if (contentType) res.setHeader("Content-Type", contentType)
      res.end()
      return
    }

    if (!upstream.body) {
      res.end()
      return
    }

    const shouldRewrite =
      looksLikeM3u8(contentType, target) ||
      (upstream.ok && /\.m3u8(?:[?#]|$)/i.test(target))

    if (shouldRewrite) {
      const raw = await upstream.text()
      const finalUrl = upstream.url || target
      const rewritten = looksLikeM3u8(contentType, target, raw)
        ? rewriteM3u8Playlist(raw, finalUrl)
        : raw
      const body = Buffer.from(rewritten, "utf8")
      res.setHeader("Content-Type", contentType || "application/vnd.apple.mpegurl")
      res.setHeader("Content-Length", String(body.byteLength))
      res.end(body)
      return
    }

    if (contentType) res.setHeader("Content-Type", contentType)
    const contentLength = upstream.headers.get("content-length")
    if (contentLength) res.setHeader("Content-Length", contentLength)

    const reader = upstream.body.getReader()
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      if (value?.byteLength) res.write(Buffer.from(value))
    }
    res.end()
  } catch (err) {
    const fallback = httpFallbackStreamUrl(target)
    if (fallback && target.startsWith("https://")) {
      try {
        console.log("[xt:stream-proxy] tls retry http", fallback.slice(0, 120))
        const upstream = await fetchUpstream(fallback)
        res.statusCode = upstream.status
        res.setHeader("Access-Control-Allow-Origin", "*")
        res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        res.setHeader(
          "Access-Control-Allow-Headers",
          "Content-Type, X-XT-UA, X-XT-Referer",
        )
        const contentType = upstream.headers.get("content-type")
        if (method === "HEAD") {
          if (contentType) res.setHeader("Content-Type", contentType)
          res.end()
          return
        }
        if (!upstream.body) {
          res.end()
          return
        }
        if (contentType) res.setHeader("Content-Type", contentType)
        const contentLength = upstream.headers.get("content-length")
        if (contentLength) res.setHeader("Content-Length", contentLength)
        const reader = upstream.body.getReader()
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          if (value?.byteLength) res.write(Buffer.from(value))
        }
        res.end()
        return
      } catch (retryErr) {
        console.warn("[xt:stream-proxy] http fallback failed:", retryErr)
      }
    }
    console.warn("[xt:stream-proxy] upstream error:", err)
    res.statusCode = 502
    res.setHeader("Content-Type", "text/plain; charset=utf-8")
    res.end(String((err as Error)?.message || err))
  }
}

export function streamProxyPlugin(): Plugin {
  return {
    name: "xtream-stream-proxy",
    apply: "serve",
    configureServer(server: ViteDevServer) {
      server.middlewares.use(PROXY_PATH, (req, res) => {
        if (req.method === "OPTIONS") {
          res.statusCode = 204
          res.setHeader("Access-Control-Allow-Origin", "*")
          res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
          res.setHeader(
            "Access-Control-Allow-Headers",
            "Content-Type, X-XT-UA, X-XT-Referer",
          )
          res.end()
          return
        }
        if (req.method !== "GET" && req.method !== "HEAD") {
          res.statusCode = 405
          res.end("Method not allowed")
          return
        }
        proxyHandler(req, res).catch((err) => {
          res.statusCode = 500
          res.end(String(err?.message || err))
        })
      })
    },
  }
}

export const STREAM_PROXY_PATH = PROXY_PATH
