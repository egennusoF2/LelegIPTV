/**
 * Dev-only reverse proxy for IPTV stream URLs (HLS segments, MPEG-TS, manifests).
 * Browsers cannot set Referer reliably and block cross-origin redirects; Node fetch can.
 */
import type { Plugin, ViteDevServer } from "vite"
import { createHash } from "node:crypto"
import { spawn } from "node:child_process"
import { mkdir, stat, unlink } from "node:fs/promises"
import { createReadStream, createWriteStream } from "node:fs"
import { PassThrough } from "node:stream"
import { join } from "node:path"
import { tmpdir } from "node:os"
import {
  looksLikeM3u8,
  rewriteM3u8Playlist,
} from "../scripts/lib/m3u8-proxy-rewrite.ts"
import { sanitizeTvMasterPlaylistIfNeeded } from "../scripts/lib/hls-manifest-sanitize.ts"
import {
  preferHttpsStreamUrl,
  httpFallbackStreamUrl,
  isIptvMediaUrl,
  resolveUpstreamUserAgent,
  IPTV_UA_VOD,
} from "../scripts/lib/stream-proxy.ts"

const PROXY_PATH = "/__stream"
const SUBTITLE_PATH = "/__vod_subtitles"
const SUBTITLE_ASSET_PATH = "/__vod_subtitles_asset"
const VOD_STREAMS_PATH = "/__vod_streams"
const VOD_REMUX_PATH = "/__vod_remux"
const VOD_SUBTITLE_PATH = "/__vod_subtitle"
const SUBTITLE_EXTRACT_MS = 90_000
const MAX_SUBTITLE_TRACKS = 32

const DEFAULT_UA = IPTV_UA_VOD

function upstreamUserAgent(target: string, clientUa: string): string {
  if (isIptvMediaUrl(target)) return resolveUpstreamUserAgent(target)
  return clientUa || DEFAULT_UA
}

const ALLOW_HEADERS = "Content-Type, Range, X-XT-UA, X-XT-Referer"
const EXPOSE_HEADERS = "Content-Length, Content-Range, Accept-Ranges"
const SUBTITLE_CACHE_DIR = join(tmpdir(), "leleg-iptv-vod-subtitles")
const REMUX_CACHE_DIR = join(tmpdir(), "leleg-iptv-vod-remux")
const subtitleExtractInflight = new Map<string, Promise<boolean>>()
const remuxInflight = new Map<string, Promise<boolean>>()
const REMUX_EXTRACT_MS = 20 * 60_000
const REMUX_READY_BYTES = 256 * 1024

function redactStreamUrl(url: string): string {
  try {
    const parsed = new URL(url)
    parsed.pathname = parsed.pathname.replace(
      /\/(live|movie|series)\/[^/]+\/[^/]+\//i,
      "/$1/***/***/",
    )
    return parsed.href
  } catch {
    return url.replace(/\/(live|movie|series)\/[^/]+\/[^/]+\//i, "/$1/***/***/")
  }
}

function applyCorsHeaders(res: import("http").ServerResponse): void {
  res.setHeader("Access-Control-Allow-Origin", "*")
  res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
  res.setHeader("Access-Control-Allow-Headers", ALLOW_HEADERS)
  res.setHeader("Access-Control-Expose-Headers", EXPOSE_HEADERS)
}

function sendJson(
  res: import("http").ServerResponse,
  status: number,
  payload: unknown,
): void {
  const body = Buffer.from(JSON.stringify(payload), "utf8")
  applyCorsHeaders(res)
  res.statusCode = status
  res.setHeader("Content-Type", "application/json; charset=utf-8")
  res.setHeader("Content-Length", String(body.byteLength))
  res.end(body)
}

function requestParam(req: import("http").IncomingMessage, key: string): string {
  const requestUrl = req.url || ""
  const qIndex = requestUrl.indexOf("?")
  const search = qIndex >= 0 ? requestUrl.slice(qIndex) : ""
  return new URLSearchParams(search).get(key) || ""
}

function mediaRequestHeaders(
  req: import("http").IncomingMessage,
  target: string,
): { userAgent: string; referer: string } {
  const userAgent =
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
  return { userAgent, referer }
}

function ffmpegHeaders(userAgent: string, referer: string): string {
  return [
    userAgent ? `User-Agent: ${userAgent}` : "",
    referer ? `Referer: ${referer}` : "",
  ].filter(Boolean).join("\n")
}

function runProcess(
  command: string,
  args: string[],
  timeoutMs: number,
): Promise<{ stdout: string; stderr: string; code: number }> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] })
    let stdout = ""
    let stderr = ""
    const timer = setTimeout(() => {
      child.kill("SIGKILL")
      reject(new Error(`${command} timed out`))
    }, timeoutMs)
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    child.stdout.on("data", (chunk) => { stdout += chunk })
    child.stderr.on("data", (chunk) => { stderr += chunk })
    child.on("error", (error) => {
      clearTimeout(timer)
      reject(error)
    })
    child.on("close", (code) => {
      clearTimeout(timer)
      resolve({ stdout, stderr, code: code ?? 0 })
    })
  })
}

type MediaProbeStream = {
  index?: number
  codec_type?: string
  codec_name?: string
  tags?: { language?: string; title?: string }
}

async function listMediaStreams(
  target: string,
  userAgent: string,
  referer: string,
): Promise<MediaProbeStream[]> {
  const headers = ffmpegHeaders(userAgent, referer)
  const args = [
    "-v", "error",
    ...(headers ? ["-headers", headers] : []),
    "-show_streams",
    "-of", "json",
    target,
  ]
  const result = await runProcess("ffprobe", args, 20_000)
  if (result.code !== 0) {
    throw new Error(result.stderr || "ffprobe failed")
  }
  const parsed = JSON.parse(result.stdout || "{}") as { streams?: MediaProbeStream[] }
  return parsed.streams || []
}

function isExtractableTextSubtitle(codec: string | undefined): boolean {
  const name = (codec || "").toLowerCase()
  if (!name) return true
  if (name.includes("hdmv") || name.includes("pgssub") || name === "dvd_subtitle") {
    return false
  }
  return true
}

function subtitleCachePaths(
  target: string,
  userAgent: string,
  referer: string,
  subtitleIndex: number,
): { hash: string; dir: string; filename: string; outPath: string } {
  const hash = createHash("sha256")
    .update(`${target}\n${userAgent}\n${referer}`)
    .digest("hex")
    .slice(0, 24)
  const filename = `sub-${subtitleIndex}.vtt`
  const dir = join(SUBTITLE_CACHE_DIR, hash)
  return { hash, dir, filename, outPath: join(dir, filename) }
}

function subtitleInflightKey(
  target: string,
  userAgent: string,
  referer: string,
  subtitleIndex: number,
): string {
  const { hash } = subtitleCachePaths(target, userAgent, referer, subtitleIndex)
  return `${hash}:${subtitleIndex}`
}

async function cachedSubtitleFile(
  outPath: string,
): Promise<boolean> {
  try {
    return (await stat(outPath)).size > 0
  } catch {
    return false
  }
}

function serveSubtitleVttFile(
  outPath: string,
  res: import("http").ServerResponse,
): void {
  applyCorsHeaders(res)
  res.statusCode = 200
  res.setHeader("Content-Type", "text/vtt; charset=utf-8")
  createReadStream(outPath).pipe(res)
}

function remuxCachePaths(
  target: string,
  userAgent: string,
  referer: string,
  audioIndex: number,
): { hash: string; dir: string; outPath: string } {
  const hash = createHash("sha256")
    .update(`${target}\n${userAgent}\n${referer}\n${audioIndex}`)
    .digest("hex")
    .slice(0, 24)
  const dir = join(REMUX_CACHE_DIR, hash)
  return { hash, dir, outPath: join(dir, `audio-${audioIndex}.mp4`) }
}

function remuxInflightKey(
  target: string,
  userAgent: string,
  referer: string,
  audioIndex: number,
): string {
  const { hash } = remuxCachePaths(target, userAgent, referer, audioIndex)
  return `${hash}:${audioIndex}`
}

async function cachedRemuxFile(outPath: string): Promise<boolean> {
  try {
    return (await stat(outPath)).size >= REMUX_READY_BYTES
  } catch {
    return false
  }
}

async function waitForRemuxFileReady(
  outPath: string,
  job: Promise<boolean>,
): Promise<boolean> {
  const deadline = Date.now() + REMUX_EXTRACT_MS
  while (Date.now() < deadline) {
    try {
      if ((await stat(outPath)).size >= REMUX_READY_BYTES) return true
    } catch {}
    const done = await Promise.race([
      job.then((ok) => (ok ? true : false)),
      new Promise<null>((resolve) => setTimeout(() => resolve(null), 500)),
    ])
    if (done === true) {
      try {
        return (await stat(outPath)).size >= REMUX_READY_BYTES
      } catch {
        return false
      }
    }
    if (done === false) return false
  }
  return false
}

async function serveMediaFileWithRange(
  filePath: string,
  req: import("http").IncomingMessage,
  res: import("http").ServerResponse,
  contentType: string,
): Promise<void> {
  let size = 0
  try {
    size = (await stat(filePath)).size
  } catch {
    res.statusCode = 404
    res.end("not found")
    return
  }
  if (size <= 0) {
    res.statusCode = 503
    res.setHeader("Retry-After", "2")
    res.end("remux not ready")
    return
  }

  applyCorsHeaders(res)
  res.setHeader("Accept-Ranges", "bytes")
  res.setHeader("Content-Type", contentType)
  res.setHeader("Cache-Control", "no-store")

  const rangeHeader =
    typeof req.headers.range === "string" ? req.headers.range : ""
  const match = /^bytes=(\d+)-(\d*)$/i.exec(rangeHeader)
  if (match) {
    const start = Math.max(0, parseInt(match[1], 10) || 0)
    let end = match[2] ? parseInt(match[2], 10) : size - 1
    if (Number.isNaN(end) || end >= size) end = size - 1
    if (start > end || start >= size) {
      res.statusCode = 416
      res.setHeader("Content-Range", `bytes */${size}`)
      res.end()
      return
    }
    res.statusCode = 206
    res.setHeader("Content-Length", String(end - start + 1))
    res.setHeader("Content-Range", `bytes ${start}-${end}/${size}`)
    createReadStream(filePath, { start, end }).pipe(res)
    return
  }

  res.statusCode = 200
  res.setHeader("Content-Length", String(size))
  createReadStream(filePath).pipe(res)
}

function runRemuxToFile(
  target: string,
  userAgent: string,
  referer: string,
  audioIndex: number,
  outPath: string,
): Promise<boolean> {
  return new Promise((resolve) => {
    const headers = ffmpegHeaders(userAgent, referer)
    const args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-probesize",
      "32M",
      "-analyzeduration",
      "10M",
      ...(headers ? ["-headers", headers] : []),
      "-i",
      target,
      "-map",
      "0:v:0?",
      "-map",
      `0:a:${audioIndex}`,
      "-c:v",
      "copy",
      "-c:a",
      "aac",
      "-b:a",
      "192k",
      "-movflags",
      "+frag_keyframe+empty_moov+default_base_moof",
      "-f",
      "mp4",
      "-y",
      outPath,
    ]
    const child = spawn("ffmpeg", args, { stdio: ["ignore", "ignore", "pipe"] })
    let stderr = ""
    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL")
      } catch {}
      resolve(false)
    }, REMUX_EXTRACT_MS)

    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk) => {
      stderr += chunk
    })
    child.on("error", () => {
      clearTimeout(timer)
      void unlink(outPath).catch(() => {})
      resolve(false)
    })
    child.on("close", (code) => {
      clearTimeout(timer)
      if (code !== 0) {
        if (stderr.trim()) {
          console.warn("[xt:vod-remux] ffmpeg", stderr.trim().slice(0, 240))
        }
        void unlink(outPath).catch(() => {})
        resolve(false)
        return
      }
      resolve(true)
    })
  })
}

async function ensureRemuxFile(
  target: string,
  userAgent: string,
  referer: string,
  audioIndex: number,
  outPath: string,
): Promise<boolean> {
  if (await cachedRemuxFile(outPath)) return true

  const key = remuxInflightKey(target, userAgent, referer, audioIndex)
  let job = remuxInflight.get(key)
  if (!job) {
    const { dir } = remuxCachePaths(target, userAgent, referer, audioIndex)
    await mkdir(dir, { recursive: true }).catch(() => {})
    job = runRemuxToFile(target, userAgent, referer, audioIndex, outPath).finally(
      () => {
        remuxInflight.delete(key)
      },
    )
    remuxInflight.set(key, job)
  }
  return waitForRemuxFileReady(outPath, job)
}

/**
 * Extract one subtitle track. Streams VTT to the client as ffmpeg produces it
 * (first cues often within a few seconds) while writing the same bytes to disk cache.
 */
function streamExtractSubtitleTrack(
  target: string,
  userAgent: string,
  referer: string,
  subtitleIndex: number,
  outPath: string,
  res: import("http").ServerResponse | null,
): Promise<boolean> {
  return new Promise((resolve) => {
    const headers = ffmpegHeaders(userAgent, referer)
    const args = [
      "-hide_banner",
      "-loglevel",
      "error",
      ...(headers ? ["-headers", headers] : []),
      "-fflags",
      "+discardcorrupt",
      "-i",
      target,
      "-map",
      `0:s:${subtitleIndex}`,
      "-c:s",
      "webvtt",
      "-f",
      "webvtt",
      "pipe:1",
    ]
    const child = spawn("ffmpeg", args, { stdio: ["ignore", "pipe", "pipe"] })
    let stderr = ""
    const fileStream = createWriteStream(outPath)
    let settled = false

    const finish = (ok: boolean) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(ok)
    }

    const timer = setTimeout(() => {
      child.kill("SIGKILL")
      finish(false)
    }, SUBTITLE_EXTRACT_MS)

    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk) => {
      stderr += chunk
    })

    if (res) {
      applyCorsHeaders(res)
      res.statusCode = 200
      res.setHeader("Content-Type", "text/vtt; charset=utf-8")
      const tee = new PassThrough()
      child.stdout.pipe(tee)
      tee.pipe(res)
      tee.pipe(fileStream)
    } else {
      child.stdout.pipe(fileStream)
    }

    const onFail = () => {
      void unlink(outPath).catch(() => {})
      if (res && !res.headersSent) {
        res.statusCode = 502
        res.setHeader("Content-Type", "text/plain; charset=utf-8")
        res.end("subtitle extract failed")
      }
      finish(false)
    }

    child.on("error", onFail)
    fileStream.on("error", onFail)
    child.stdout.on("error", onFail)

    child.on("close", (code) => {
      if (code !== 0) {
        if (stderr) {
          console.warn("[xt:vod-subtitle] ffmpeg", stderr.slice(0, 240))
        }
        onFail()
        return
      }
      finish(true)
    })
  })
}

async function runSubtitleExtract(
  target: string,
  userAgent: string,
  referer: string,
  subtitleIndex: number,
  outPath: string,
  res: import("http").ServerResponse | null,
): Promise<boolean> {
  const key = subtitleInflightKey(target, userAgent, referer, subtitleIndex)
  const existing = subtitleExtractInflight.get(key)
  if (existing) return existing

  const job = streamExtractSubtitleTrack(
    target,
    userAgent,
    referer,
    subtitleIndex,
    outPath,
    res,
  ).finally(() => {
    subtitleExtractInflight.delete(key)
  })
  subtitleExtractInflight.set(key, job)
  return job
}

function listSubtitleMetadata(
  streams: MediaProbeStream[],
  target: string,
): Array<{ index: number; label: string; language: string; src: string; codec: string }> {
  const subtitleStreams = streams.filter((s) => s.codec_type === "subtitle")
  const tracks: Array<{
    index: number
    label: string
    language: string
    src: string
    codec: string
  }> = []
  for (let i = 0; i < Math.min(subtitleStreams.length, MAX_SUBTITLE_TRACKS); i++) {
    const stream = subtitleStreams[i]
    const codec = stream.codec_name || ""
    if (!isExtractableTextSubtitle(codec)) continue
    const language = stream.tags?.language || ""
    const label = stream.tags?.title || language || `Subtitle ${i + 1}`
    tracks.push({
      index: i,
      language,
      label,
      codec,
      src: `${VOD_SUBTITLE_PATH}?url=${encodeURIComponent(target)}&index=${i}`,
    })
  }
  return tracks
}

async function vodSubtitleHandler(
  req: import("http").IncomingMessage,
  res: import("http").ServerResponse,
): Promise<void> {
  let target = requestParam(req, "url")
  if (target) target = preferHttpsStreamUrl(target)
  const subtitleIndex = Math.max(0, parseInt(requestParam(req, "index") || "0", 10) || 0)
  if (!target || !isAllowedTarget(target)) {
    res.statusCode = 400
    res.end("invalid url")
    return
  }

  const clientUa =
    (typeof req.headers["x-xt-ua"] === "string" && req.headers["x-xt-ua"]) || ""
  const userAgent = upstreamUserAgent(target, clientUa)
  const { referer } = mediaRequestHeaders(req, target)

  const { dir, outPath } = subtitleCachePaths(target, userAgent, referer, subtitleIndex)
  await mkdir(dir, { recursive: true })

  if (await cachedSubtitleFile(outPath)) {
    console.log("[xt:vod-subtitle] cache hit", subtitleIndex)
    serveSubtitleVttFile(outPath, res)
    return
  }

  const inflight = subtitleInflightKey(target, userAgent, referer, subtitleIndex)
  if (subtitleExtractInflight.has(inflight)) {
    console.log("[xt:vod-subtitle] wait inflight", subtitleIndex)
    const ok = await subtitleExtractInflight.get(inflight)!
    if (ok && (await cachedSubtitleFile(outPath))) {
      serveSubtitleVttFile(outPath, res)
    } else if (!res.headersSent) {
      res.statusCode = 502
      res.setHeader("Content-Type", "text/plain; charset=utf-8")
      res.end("subtitle extract failed")
    }
    return
  }

  console.log(
    "[xt:vod-subtitle] stream extract",
    redactStreamUrl(target).slice(0, 120),
    "index:",
    subtitleIndex,
  )

  const ok = await runSubtitleExtract(
    target,
    userAgent,
    referer,
    subtitleIndex,
    outPath,
    res,
  )
  if (!ok && !res.headersSent) {
    res.statusCode = 502
    res.setHeader("Content-Type", "text/plain; charset=utf-8")
    res.end("subtitle extract failed")
  }
}

async function subtitleHandler(
  req: import("http").IncomingMessage,
  res: import("http").ServerResponse,
): Promise<void> {
  let target = requestParam(req, "url")
  if (target) target = preferHttpsStreamUrl(target)
  if (!target || !isAllowedTarget(target)) {
    sendJson(res, 400, { tracks: [], error: "invalid url" })
    return
  }

  const clientUa =
    (typeof req.headers["x-xt-ua"] === "string" && req.headers["x-xt-ua"]) || ""
  const userAgent = upstreamUserAgent(target, clientUa)
  const { referer } = mediaRequestHeaders(req, target)

  console.log("[xt:vod-subtitles] metadata", redactStreamUrl(target).slice(0, 160))

  const streams = await listMediaStreams(target, userAgent, referer)
  const tracks = listSubtitleMetadata(streams, target).map(({ codec: _codec, ...track }) => track)
  sendJson(res, 200, { tracks })
}

async function vodStreamsHandler(
  req: import("http").IncomingMessage,
  res: import("http").ServerResponse,
): Promise<void> {
  let target = requestParam(req, "url")
  if (target) target = preferHttpsStreamUrl(target)
  if (!target || !isAllowedTarget(target)) {
    sendJson(res, 400, { audio: [], subtitles: [], error: "invalid url" })
    return
  }

  const clientUa =
    (typeof req.headers["x-xt-ua"] === "string" && req.headers["x-xt-ua"]) || ""
  const userAgent = upstreamUserAgent(target, clientUa)
  const { referer } = mediaRequestHeaders(req, target)

  console.log("[xt:vod-streams]", redactStreamUrl(target).slice(0, 160))

  try {
    const streams = await listMediaStreams(target, userAgent, referer)
    const audio = streams
      .filter((stream) => stream.codec_type === "audio")
      .map((stream, index) => ({
        index,
        language: stream.tags?.language || "",
        label: stream.tags?.title || stream.tags?.language || "",
        codec: stream.codec_name || "",
      }))
    const subtitles = listSubtitleMetadata(streams, target)
    console.log(
      "[xt:vod-streams] tracks",
      "audio:",
      audio.length,
      "subtitles:",
      subtitles.length,
      "(lazy extract)",
    )
    sendJson(res, 200, { audio, subtitles })
  } catch (err) {
    console.warn("[xt:vod-streams] error:", err)
    sendJson(res, 502, { audio: [], subtitles: [], error: String((err as Error)?.message || err) })
  }
}

async function vodRemuxHandler(
  req: import("http").IncomingMessage,
  res: import("http").ServerResponse,
): Promise<void> {
  let target = requestParam(req, "url")
  if (target) target = preferHttpsStreamUrl(target)
  const audioIdx = Math.max(0, parseInt(requestParam(req, "audio") || "0", 10) || 0)
  if (!target || !isAllowedTarget(target)) {
    res.statusCode = 400
    res.end("invalid url")
    return
  }

  const clientUa =
    (typeof req.headers["x-xt-ua"] === "string" && req.headers["x-xt-ua"]) || ""
  const userAgent = upstreamUserAgent(target, clientUa)
  const { referer } = mediaRequestHeaders(req, target)
  const { outPath } = remuxCachePaths(target, userAgent, referer, audioIdx)

  console.log("[xt:vod-remux]", redactStreamUrl(target).slice(0, 160), "audio:", audioIdx)

  const ready = await ensureRemuxFile(target, userAgent, referer, audioIdx, outPath)
  if (!ready) {
    res.statusCode = 502
    res.setHeader("Content-Type", "text/plain; charset=utf-8")
    res.end("remux failed")
    return
  }

  await serveMediaFileWithRange(outPath, req, res, "video/mp4")
}

async function subtitleAssetHandler(
  req: import("http").IncomingMessage,
  res: import("http").ServerResponse,
): Promise<void> {
  const id = requestParam(req, "id")
  const file = requestParam(req, "file")
  if (!/^[a-f0-9]{24}$/.test(id) || !/^sub-\d+\.vtt$/.test(file)) {
    res.statusCode = 400
    res.end("invalid subtitle asset")
    return
  }
  const path = join(SUBTITLE_CACHE_DIR, id, file)
  try {
    await stat(path)
    applyCorsHeaders(res)
    res.statusCode = 200
    res.setHeader("Content-Type", "text/vtt; charset=utf-8")
    createReadStream(path).pipe(res)
  } catch {
    res.statusCode = 404
    res.end("not found")
  }
}

function applyUpstreamMetadata(
  upstream: Response,
  res: import("http").ServerResponse,
): void {
  const contentType = upstream.headers.get("content-type")
  if (contentType) res.setHeader("Content-Type", contentType)
  const contentLength = upstream.headers.get("content-length")
  if (contentLength) res.setHeader("Content-Length", contentLength)
  const contentRange = upstream.headers.get("content-range")
  if (contentRange) res.setHeader("Content-Range", contentRange)
  const acceptRanges = upstream.headers.get("accept-ranges")
  if (acceptRanges) res.setHeader("Accept-Ranges", acceptRanges)
}

function isBenignProxyDisconnect(err: unknown): boolean {
  const message = String((err as Error)?.message || err)
  const cause = (err as { code?: string; message?: string })?.cause
  const causeCode = cause?.code || ""
  const causeMessage = String(cause?.message || "")
  return (
    message === "terminated" ||
    /terminated|aborted|other side closed|ECONNRESET/i.test(message) ||
    /terminated|aborted|other side closed/i.test(causeMessage) ||
    (err as Error)?.name === "AbortError" ||
    causeCode === "UND_ERR_SOCKET" ||
    causeCode === "ABORT_ERR" ||
    causeCode === "ECONNRESET"
  )
}

async function pumpUpstreamBody(
  upstream: Response,
  res: import("http").ServerResponse,
  clientClosed: () => boolean,
): Promise<void> {
  if (!upstream.body) return
  const reader = upstream.body.getReader()
  try {
    while (!clientClosed()) {
      const { done, value } = await reader.read()
      if (done) break
      if (clientClosed()) break
      if (value?.byteLength) res.write(Buffer.from(value))
    }
  } finally {
    try {
      await reader.cancel()
    } catch {}
  }
}

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

  const clientUa =
    (typeof req.headers["x-xt-ua"] === "string" && req.headers["x-xt-ua"]) || ""
  const ua = upstreamUserAgent(target, clientUa)
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
  const fetchHeaders: Record<string, string> = {
    "User-Agent": ua,
    ...(referer ? { Referer: referer } : {}),
  }
  if (typeof req.headers.range === "string" && req.headers.range) {
    fetchHeaders.Range = req.headers.range
  }
  console.log("[xt:stream-proxy]", req.method, redactStreamUrl(target).slice(0, 160))

  const upstreamAbort = new AbortController()
  let clientClosed = false
  const markClientClosed = () => {
    clientClosed = true
    try {
      upstreamAbort.abort()
    } catch {}
  }
  upstreamAbort.signal.addEventListener("abort", () => {
    clientClosed = true
  })
  req.on("close", markClientClosed)
  res.on("close", markClientClosed)

  async function fetchUpstream(url: string) {
    return fetch(url, {
      method,
      headers: fetchHeaders,
      redirect: "follow",
      signal: upstreamAbort.signal,
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
        console.log("[xt:stream-proxy] retry http", redactStreamUrl(fallback).slice(0, 160))
        upstream = await fetchUpstream(fallback)
      }
    }

    res.statusCode = upstream.status
    applyCorsHeaders(res)

    const contentType = upstream.headers.get("content-type")

    if (method === "HEAD") {
      applyUpstreamMetadata(upstream, res)
      res.end()
      return
    }

    if (!upstream.body) {
      res.end()
      return
    }

    const urlSuggestsM3u8 = /\.m3u8(?:[?#]|$)/i.test(target)
    const shouldInspectManifest =
      urlSuggestsM3u8 ||
      looksLikeM3u8(contentType, target) ||
      (upstream.ok && urlSuggestsM3u8)

    if (shouldInspectManifest) {
      const raw = await upstream.text()
      const finalUrl = upstream.url || target
      if (urlSuggestsM3u8) {
        const mediaLines = raw.match(/^#EXT-X-MEDIA:.*$/gim)?.length || 0
        console.log(
          "[xt:stream-proxy] m3u8 status:",
          upstream.status,
          "content-type:",
          contentType,
          "media-lines:",
          mediaLines,
        )
      }
      if (!looksLikeM3u8(contentType, target, raw)) {
        const quietStatus =
          upstream.status === 401 ||
          upstream.status === 403 ||
          upstream.status === 404 ||
          upstream.status === 551
        const logFn = quietStatus ? console.debug : console.warn
        logFn(
          "[xt:stream-proxy] upstream is not HLS manifest",
          upstream.status,
          redactStreamUrl(target).slice(0, 120),
        )
        res.statusCode =
          upstream.status >= 400 && upstream.status < 600 ? upstream.status : 502
        res.setHeader("Content-Type", "text/plain; charset=utf-8")
        res.end(`Upstream returned non-HLS body (HTTP ${upstream.status})`)
        return
      }
      let rewritten = rewriteM3u8Playlist(raw, finalUrl)
      rewritten = sanitizeTvMasterPlaylistIfNeeded(rewritten)
      const body = Buffer.from(rewritten, "utf8")
      res.setHeader("Content-Type", contentType || "application/vnd.apple.mpegurl")
      res.setHeader("Content-Length", String(body.byteLength))
      res.end(body)
      return
    }

    applyUpstreamMetadata(upstream, res)

    try {
      await pumpUpstreamBody(upstream, res, () => clientClosed)
    } catch (pumpErr) {
      if (!clientClosed && !isBenignProxyDisconnect(pumpErr)) throw pumpErr
    }
    if (!clientClosed && !res.writableEnded) res.end()
    return
  } catch (err) {
    if (clientClosed || isBenignProxyDisconnect(err)) {
      if (!res.writableEnded) {
        try {
          res.end()
        } catch {}
      }
      return
    }
    const fallback = httpFallbackStreamUrl(target)
    if (fallback && target.startsWith("https://")) {
      try {
        console.log("[xt:stream-proxy] tls retry http", redactStreamUrl(fallback).slice(0, 160))
        const upstream = await fetchUpstream(fallback)
        res.statusCode = upstream.status
        applyCorsHeaders(res)
        if (method === "HEAD") {
          applyUpstreamMetadata(upstream, res)
          res.end()
          return
        }
        if (!upstream.body) {
          res.end()
          return
        }
        applyUpstreamMetadata(upstream, res)
        await pumpUpstreamBody(upstream, res, () => clientClosed)
        if (!clientClosed && !res.writableEnded) res.end()
        return
      } catch (retryErr) {
        if (!clientClosed && !isBenignProxyDisconnect(retryErr)) {
          console.warn("[xt:stream-proxy] http fallback failed:", retryErr)
        }
      }
    }
    if (clientClosed || isBenignProxyDisconnect(err)) {
      if (!res.writableEnded) {
        try {
          res.end()
        } catch {}
      }
      return
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
      server.middlewares.use(VOD_STREAMS_PATH, (req, res) => {
        if (req.method === "OPTIONS") {
          res.statusCode = 204
          applyCorsHeaders(res)
          res.end()
          return
        }
        if (req.method !== "GET") {
          res.statusCode = 405
          res.end("Method not allowed")
          return
        }
        vodStreamsHandler(req, res).catch((err) => {
          console.warn("[xt:vod-streams] handler error:", err)
          sendJson(res, 502, { audio: [], subtitles: [], error: String(err?.message || err) })
        })
      })
      server.middlewares.use(VOD_SUBTITLE_PATH, (req, res) => {
        if (req.method === "OPTIONS") {
          res.statusCode = 204
          applyCorsHeaders(res)
          res.end()
          return
        }
        if (req.method !== "GET") {
          res.statusCode = 405
          res.end("Method not allowed")
          return
        }
        vodSubtitleHandler(req, res).catch((err) => {
          console.warn("[xt:vod-subtitle] handler error:", err)
          if (!res.headersSent) res.statusCode = 502
          if (!res.writableEnded) res.end(String((err as Error)?.message || err))
        })
      })
      server.middlewares.use(VOD_REMUX_PATH, (req, res) => {
        if (req.method === "OPTIONS") {
          res.statusCode = 204
          applyCorsHeaders(res)
          res.end()
          return
        }
        if (req.method !== "GET" && req.method !== "HEAD") {
          res.statusCode = 405
          res.end("Method not allowed")
          return
        }
        if (req.method === "HEAD") {
          res.statusCode = 200
          applyCorsHeaders(res)
          res.end()
          return
        }
        vodRemuxHandler(req, res).catch((err) => {
          console.warn("[xt:vod-remux] handler error:", err)
          if (!res.headersSent) res.statusCode = 502
          if (!res.writableEnded) res.end(String(err?.message || err))
        })
      })
      server.middlewares.use(SUBTITLE_PATH, (req, res) => {
        if (req.method === "OPTIONS") {
          res.statusCode = 204
          applyCorsHeaders(res)
          res.end()
          return
        }
        if (req.method !== "GET") {
          res.statusCode = 405
          res.end("Method not allowed")
          return
        }
        subtitleHandler(req, res).catch((err) => {
          console.warn("[xt:vod-subtitles] error:", err)
          sendJson(res, 502, { tracks: [], error: String(err?.message || err) })
        })
      })
      server.middlewares.use(SUBTITLE_ASSET_PATH, (req, res) => {
        if (req.method !== "GET") {
          res.statusCode = 405
          res.end("Method not allowed")
          return
        }
        subtitleAssetHandler(req, res).catch((err) => {
          res.statusCode = 500
          res.end(String(err?.message || err))
        })
      })
      server.middlewares.use(PROXY_PATH, (req, res) => {
        if (req.method === "OPTIONS") {
          res.statusCode = 204
          applyCorsHeaders(res)
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
