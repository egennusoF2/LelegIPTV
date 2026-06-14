#!/usr/bin/env node
/**
 * Tizen TV dev server — serves build/tizen-web with no-cache headers
 * so the TV always fetches fresh files without needing a WGT reinstall.
 * Also exposes:
 *   POST /tizen-log            — JS error logging from the TV browser
 *   GET  /__stream?url=<url>   — Stream proxy (CORS bypass for IPTV APIs)
 */
import { createServer } from "node:http"
import { get as httpGet } from "node:http"
import { get as httpsGet } from "node:https"
import { createReadStream, statSync, existsSync } from "node:fs"
import { join, extname, resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..", "build", "tizen-web")
const PORT = 8099

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js":   "application/javascript; charset=utf-8",
  ".css":  "text/css; charset=utf-8",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".png":  "image/png",
  ".svg":  "image/svg+xml",
  ".ico":  "image/x-icon",
  ".woff": "font/woff",
  ".woff2":"font/woff2",
  ".xml":  "application/xml",
}

const server = createServer((req, res) => {
  const ts = new Date().toISOString().slice(11,19)

  // JS error logging endpoint — receives errors from the TV browser
  if (req.method === "POST" && req.url === "/tizen-log") {
    let body = ""
    req.on("data", d => body += d)
    req.on("end", () => {
      try {
        const obj = JSON.parse(body)
        console.error(`[${ts}] *** TV JS ${(obj.type||"LOG").toUpperCase()}: ${obj.msg || obj.reason || body}`)
        if (obj.src) console.error(`         at ${obj.src}:${obj.line}:${obj.col}`)
        if (obj.stack) console.error(`         ${obj.stack.slice(0,300)}`)
      } catch { console.error(`[${ts}] *** TV LOG: ${body.slice(0,500)}`) }
      res.writeHead(204, { "Access-Control-Allow-Origin": "*" })
      res.end()
    })
    return
  }

  // Stream proxy endpoint — CORS bypass for IPTV API / stream URLs.
  if (req.url && req.url.startsWith("/__stream?")) {
    const raw = req.url.slice("/__stream?".length)
    const params = new URLSearchParams(raw)
    const target = params.get("url")
    if (!target) { res.writeHead(400); res.end("Missing url param"); return }

    function fetchProxy(url, hops) {
      if (hops > 5) { res.writeHead(502); res.end("Too many redirects"); return }
      console.log(`[${ts}] PROXY${hops>0?" →("+hops+")":""} → ${url.slice(0, 80)}`)
      const mod = url.startsWith("https") ? httpsGet : httpGet
      const proxyReq = mod(url, { headers: { "User-Agent": "Mozilla/5.0", "Accept": "*/*" } }, (proxyRes) => {
        const sc = proxyRes.statusCode || 200
        if ((sc === 301 || sc === 302 || sc === 307 || sc === 308) && proxyRes.headers.location) {
          proxyRes.resume() // drain response body
          fetchProxy(proxyRes.headers.location, hops + 1)
          return
        }
        res.writeHead(sc, {
          "Content-Type": proxyRes.headers["content-type"] || "application/json",
          "Access-Control-Allow-Origin": "*",
          "Cache-Control": "no-cache",
        })
        proxyRes.pipe(res)
      })
      proxyReq.on("error", (e) => { console.error(`PROXY ERR: ${e.message}`); if (!res.headersSent) { res.writeHead(502); res.end(e.message) } })
      proxyReq.setTimeout(15000, () => { proxyReq.destroy() })
    }
    fetchProxy(target, 0)
    return
  }
  if (req.method === "OPTIONS") {
    res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST", "Access-Control-Allow-Headers": "Content-Type" })
    res.end()
    return
  }

  console.log(`[${ts}] ${req.socket.remoteAddress}  ${req.method} ${req.url}`)
  let url = req.url.split("?")[0].split("#")[0]

  // Try exact path, then with /index.html appended
  let filePath = join(root, url)
  if (!existsSync(filePath) || statSync(filePath).isDirectory()) {
    filePath = join(root, url.replace(/\/?$/, "/index.html"))
  }
  if (!existsSync(filePath)) {
    res.writeHead(404); res.end("Not found"); return
  }

  const ext = extname(filePath).toLowerCase()
  const mime = MIME[ext] || "application/octet-stream"
  const headers = {
    "Content-Type": mime,
    "Cache-Control": "no-cache, no-store, must-revalidate",
    "Pragma": "no-cache",
    "Expires": "0",
    "Access-Control-Allow-Origin": "*",
  }
  res.writeHead(200, headers)
  createReadStream(filePath).pipe(res)
})

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Tizen dev server → http://0.0.0.0:${PORT}  (serving ${root})`)
  console.log("No-cache enabled — TV picks up changes on app relaunch, no reinstall needed.")
  console.log("JS errors from TV → POST /tizen-log")
})
