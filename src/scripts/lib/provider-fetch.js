import { log, redactUrl } from "@/scripts/lib/log.js"
import { getUserAgent } from "@/scripts/lib/app-settings.js"
import {
  STREAM_PROXY_PATH,
  useDevStreamProxy,
  devProxyFetchHeaders,
  resolveUpstreamUserAgent,
  isStreamProxyFetchUrl,
  isNativeMediaProxyUrl,
  streamProxyOrigin,
  unwrapStreamProxyUrl,
} from "@/scripts/lib/stream-proxy.ts"

const isTauri =
  typeof window !== "undefined" &&
  (!!window.__TAURI_INTERNALS__ || !!window.__TAURI__)

/** Route cross-origin provider API/EPG through same-origin /__stream (bypasses CORS). */
function wrapProviderUrlForWeb(url) {
  if (!useDevStreamProxy() || typeof window === "undefined") return url
  if (String(url).startsWith(STREAM_PROXY_PATH + "?")) return url
  try {
    const parsed = new URL(String(url), window.location.origin)
    if (parsed.origin === window.location.origin) return url
  } catch {
    return url
  }
  const base = streamProxyOrigin()
  if (base && isTauri) {
    return `${base}${STREAM_PROXY_PATH}?url=${encodeURIComponent(String(url))}`
  }
  return `${STREAM_PROXY_PATH}?url=${encodeURIComponent(String(url))}`
}

let tauriFetchPromise = null
async function getTauriFetch() {
  if (!isTauri) return null
  if (!tauriFetchPromise) {
    tauriFetchPromise = import("@tauri-apps/plugin-http")
      .then((m) => m.fetch)
      .catch((e) => {
        log.error("[xt:net] plugin-http unavailable:", e)
        return null
      })
  }
  return tauriFetchPromise
}

async function nativeFetch(url, init, u, callerSignal) {
  try {
    const r = await fetch(url, init)
    log.log(`[xt:net] native ok ${r.status}`, u)
    return r
  } catch (e) {
    if (!callerSignal?.aborted) {
      log.error("[xt:net] native fetch failed", {
        url: u,
        error: String(e?.message || e || "unknown"),
      })
    }
    throw e
  }
}

/**
 * Drain a Response body to text, calling onProgress(received, total) as
 * bytes accumulate. `total` comes from the Content-Length header (0 if
 * the server didn't send one - chunked encoding etc.). If the body isn't
 * a readable stream (some Tauri http plugin builds buffer eagerly), we
 * fall back to response.text() with a single final progress callback.
 *
 * @param {Response} response
 * @param {(received: number, total: number) => void} [onProgress]
 * @returns {Promise<string>}
 */
export async function streamingText(response, onProgress) {
  const total = Number(response.headers?.get?.("content-length")) || 0
  const body = response.body
  if (!body || typeof body.getReader !== "function") {
    const text = await response.text()
    if (onProgress) {
      try { onProgress(text.length, total) } catch {}
    }
    return text
  }
  const reader = body.getReader()
  const decoder = new TextDecoder("utf-8")
  let received = 0
  let result = ""
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      if (value && value.byteLength) {
        received += value.byteLength
        result += decoder.decode(value, { stream: true })
        if (onProgress) {
          try { onProgress(received, total) } catch {}
        }
      }
    }
    result += decoder.decode()
  } finally {
    try { reader.releaseLock() } catch {}
  }
  return result
}

const DEFAULT_TIMEOUT_MS = 20_000

// Lightweight provider-fetch statistics
const _stats = {
  lastSuccessAt: 0,
  lastFailureAt: 0,
  lastError: "",
  successes: 0,
  failures: 0,
  lastStatus: 0,
}

function noteSuccess(status) {
  _stats.lastSuccessAt = Date.now()
  _stats.lastStatus = status || 0
  _stats.successes++
}

function noteFailure(error) {
  _stats.lastFailureAt = Date.now()
  _stats.lastError = String(error?.message || error || "").slice(0, 200)
  _stats.failures++
}

export function getProviderStats() {
  return { ..._stats }
}

function parseNativeProxyRequest(url) {
  try {
    let current = String(url)
    let ua
    let referer
    for (let depth = 0; depth < 6; depth++) {
      const parsed = new URL(current)
      if (
        !(
          (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost") &&
          (parsed.pathname === "/__stream" || parsed.pathname === "/stream")
        )
      ) {
        break
      }
      const inner = parsed.searchParams.get("url")
      if (!inner) return null
      ua = ua || parsed.searchParams.get("ua") || undefined
      referer = referer || parsed.searchParams.get("referer") || undefined
      current = decodeURIComponent(inner)
    }
    return {
      target: unwrapStreamProxyUrl(current),
      ua,
      referer,
    }
  } catch {
    return null
  }
}

async function invokeMediaProxyFetch(url, init, u, callerSignal) {
  const req = parseNativeProxyRequest(url)
  if (!req?.target) throw new Error("invalid native proxy URL")
  const headers = new Headers(init.headers || {})
  const upstream = req.target
  const effectiveUa =
    headers.get("x-xt-ua") ||
    headers.get("User-Agent") ||
    req.ua ||
    resolveUpstreamUserAgent(upstream)
  const referer =
    headers.get("x-xt-referer") ||
    headers.get("Referer") ||
    req.referer ||
    undefined
  const range = headers.get("Range") || undefined
  const method = String(init.method || "GET").toUpperCase()

  const { invoke } = await import("@tauri-apps/api/core")
  log.log(`[xt:net] proxy invoke`, redactUrl(upstream).slice(0, 200))
  const result = await invoke("media_proxy_fetch", {
    url: upstream,
    method,
    range,
    userAgent: effectiveUa,
    referer,
  })
  if (callerSignal?.aborted) {
    throw new DOMException("Aborted", "AbortError")
  }
  const raw = result?.body
  const bytes =
    raw instanceof Uint8Array
      ? raw
      : Array.isArray(raw)
        ? new Uint8Array(raw)
        : new Uint8Array(0)
  const hdrs = new Headers()
  for (const [key, value] of Object.entries(result?.headers || {})) {
    if (value != null && value !== "") hdrs.set(key, String(value))
  }
  log.log(`[xt:net] proxy ok ${result?.status ?? 0}`, u)
  return new Response(bytes, {
    status: Number(result?.status) || 0,
    headers: hdrs,
  })
}

function isSameOriginMediaProxyUrl(url) {
  if (typeof window === "undefined") return false
  try {
    const parsed = new URL(String(url), window.location.origin)
    if (parsed.pathname === "/__stream" || parsed.pathname.endsWith("/__stream")) {
      return parsed.origin === window.location.origin
    }
    if (
      (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost") &&
      parsed.pathname.startsWith("/stream")
    ) {
      return true
    }
  } catch {}
  return false
}

/** Fetch upstream IPTV URL via Rust (no loopback HTTP). Use for probes and native proxy mode. */
export async function providerFetchUpstream(url, init = {}) {
  if (!isTauri) {
    return providerFetch(url, init)
  }
  const u = redactUrl(String(url)).slice(0, 200)
  const callInit = { ...init }
  delete callInit.forceTauri
  log.log(`[xt:net] proxy start`, u)
  try {
    const headers = new Headers(callInit.headers || {})
    const upstream = unwrapStreamProxyUrl(String(url))
    const effectiveUa =
      headers.get("x-xt-ua") ||
      headers.get("User-Agent") ||
      resolveUpstreamUserAgent(upstream)
    const referer =
      headers.get("x-xt-referer") ||
      headers.get("Referer") ||
      undefined
    const range = headers.get("Range") || undefined
    const method = String(callInit.method || "GET").toUpperCase()
    const { invoke } = await import("@tauri-apps/api/core")
    log.log(`[xt:net] proxy invoke`, redactUrl(upstream).slice(0, 200))
    const result = await invoke("media_proxy_fetch", {
      url: upstream,
      method,
      range,
      userAgent: effectiveUa,
      referer,
    })
    const raw = result?.body
    const bytes =
      raw instanceof Uint8Array
        ? raw
        : Array.isArray(raw)
          ? new Uint8Array(raw)
          : new Uint8Array(0)
    const hdrs = new Headers()
    for (const [key, value] of Object.entries(result?.headers || {})) {
      if (value != null && value !== "") hdrs.set(key, String(value))
    }
    log.log(`[xt:net] proxy ok ${result?.status ?? 0}`, u)
    noteSuccess(Number(result?.status) || 0)
    return new Response(bytes, {
      status: Number(result?.status) || 0,
      headers: hdrs,
    })
  } catch (e) {
    noteFailure(e)
    throw e
  }
}

export async function providerFetch(url, init = {}) {
  const ua = getUserAgent()
  const u = redactUrl(String(url)).slice(0, 200)
  const forceTauri = !!init.forceTauri

  const callerSignal = init.signal
  const callInit = { ...init }
  delete callInit.forceTauri
  if (!callerSignal) {
    if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") {
      callInit.signal = AbortSignal.timeout(DEFAULT_TIMEOUT_MS)
    } else if (typeof AbortController !== "undefined") {
      const controller = new AbortController()
      setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS)
      callInit.signal = controller.signal
    }
  }

  // Cross-origin IPTV + loopback /__stream must use plugin-http (WKWebView fetch fails on both).
  const useTauri =
    forceTauri ||
    (isTauri &&
      (isNativeMediaProxyUrl(url) ||
        (!isSameOriginMediaProxyUrl(url) &&
          !isStreamProxyFetchUrl(url))))

  if (isTauri && isNativeMediaProxyUrl(url)) {
    log.log(`[xt:net] proxy start`, u)
    try {
      const r = await invokeMediaProxyFetch(url, callInit, u, callerSignal)
      noteSuccess(r.status)
      return r
    } catch (e) {
      if (callerSignal?.aborted) throw e
      log.error("[xt:net] proxy invoke failed", {
        url: u,
        error: String(e?.message || e),
      })
      noteFailure(e)
      throw e
    }
  }

  if (!useTauri) {
    const headers = new Headers(callInit.headers || {})
    if (ua && !headers.has("User-Agent")) {
      headers.set("User-Agent", ua)
    }
    callInit.headers = headers
    const fetchUrl = wrapProviderUrlForWeb(url)
    if (fetchUrl !== url) {
      for (const [key, value] of Object.entries(devProxyFetchHeaders(headers))) {
        if (value) headers.set(key, value)
      }
      callInit.headers = headers
    }
    log.log(`[xt:net] native start`, u)
    try {
      const r = await nativeFetch(fetchUrl, callInit, u, callerSignal)
      noteSuccess(r.status)
      return r
    } catch (e) {
      if (!callerSignal?.aborted) noteFailure(e)
      throw e
    }
  }

  const tauriFetch = await getTauriFetch()
  if (!tauriFetch) {
    log.log(`[xt:net] native start (no plugin-http)`, u)
    try {
      const r = await nativeFetch(url, callInit, u, callerSignal)
      noteSuccess(r.status)
      return r
    } catch (e) {
      if (!callerSignal?.aborted) noteFailure(e)
      throw e
    }
  }

  log.log(`[xt:net] tauri start ua=${ua || "(iptv-default)"}`, u)
  const headers = new Headers(callInit.headers || {})
  const upstream = isStreamProxyFetchUrl(url)
    ? unwrapStreamProxyUrl(url)
    : String(url)
  const effectiveUa = ua || resolveUpstreamUserAgent(upstream)
  if (effectiveUa) {
    headers.set("User-Agent", effectiveUa)
  }
  try {
    const r = await tauriFetch(url, { ...callInit, headers })
    log.log(`[xt:net] tauri ok ${r.status}`, u)
    noteSuccess(r.status)
    return r
  } catch (e) {
    if (callerSignal?.aborted) throw e
    const msg = String(e?.message || e)
    if (
      /not allowed on the configured scope/i.test(msg) &&
      isNativeMediaProxyUrl(url)
    ) {
      log.error(
        "[xt:net] loopback /__stream blocked by Tauri HTTP scope (rebuild .app after capabilities change):",
        msg
      )
      noteFailure(e)
      throw e
    }
    log.warn("[xt:net] tauri fetch failed, falling back to native:", msg)
    try {
      const r = await nativeFetch(url, callInit, u, callerSignal)
      noteSuccess(r.status)
      return r
    } catch (e2) {
      if (!callerSignal?.aborted) noteFailure(e2)
      throw e2
    }
  }
}
