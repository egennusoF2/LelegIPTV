// Playlist storage + Xtream/M3U URL helpers.
//
// Storage shape (one JSON blob under "xt_playlists"):
//   { entries: PlaylistEntry[], selectedId: string }
//
// PlaylistEntry =
//   | { _id, title, type: "xtream",    serverUrl, username, password,  epgUrl?, additionalEpgUrls?, disableProviderEpg?, addedAt, lastUsedAt? }
//   | { _id, title, type: "m3u",       url,                            epgUrl?, additionalEpgUrls?, disableProviderEpg?, addedAt, lastUsedAt? }
//   | { _id, title, type: "local-m3u", sourceName,                     epgUrl?, additionalEpgUrls?, disableProviderEpg?, addedAt, lastUsedAt? }
//
// `epgUrl` is an optional user-supplied primary XMLTV URL that overrides the
// provider's default (`xmltv.php` for Xtream, the M3U `x-tvg-url` header for
// M3U sources). `additionalEpgUrls` is a waterfall list of extra XMLTV URLs
// merged in after the primary — each fills `tvg-id` keys the previous sources
// didn't supply (no override; primary always wins on conflict).
// `disableProviderEpg` suppresses the auto-detected provider default when no
// primary override is set, letting the user verify their additional sources
// in isolation.
//
// Tauri builds persist via @tauri-apps/plugin-store; web/SSR via localStorage
// + cookies. Old "xt_host" / "xt_port" / "xt_user" / "xt_pass" keys are
// auto-migrated into one entry on first read.

import { log } from "@/scripts/lib/log.js"
import { Store } from "@tauri-apps/plugin-store"

export const isTauri =
  typeof window !== "undefined" &&
  (!!window.__TAURI_INTERNALS__ || !!window.__TAURI__)

const STORAGE_KEY = "xt_playlists"
const LEGACY_KEYS = ["host", "port", "user", "pass"]
const EVT_ACTIVE_CHANGED = "xt:active-changed"
const EVT_ENTRIES_UPDATED = "xt:entries-updated"
export const LOCAL_M3U_SCHEME = "xt-local://"

let storePromise = null
function getStore() {
  if (!isTauri) return Promise.resolve(null)
  if (!storePromise) {
    storePromise = Store.load(".xtream.creds.json").catch((e) => {
      log.error(
        "[xt:creds] plugin-store unavailable, falling back to localStorage:",
        e
      )
      return null
    })
  }
  return storePromise
}

const getCookie = (name) => {
  try {
    const m = document.cookie.match(
      new RegExp(
        "(?:^|; )" +
          name.replace(/([.$?*|{}()[\]\\/+^])/g, "\\$1") +
          "=([^;]*)"
      )
    )
    return m ? decodeURIComponent(m[1]) : ""
  } catch {
    return ""
  }
}
const setCookie = (name, value, days = 365) => {
  try {
    const d = new Date()
    d.setTime(d.getTime() + days * 864e5)
    document.cookie = `${name}=${encodeURIComponent(
      value
    )}; expires=${d.toUTCString()}; path=/`
  } catch {}
}

const uuid = () =>
  typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`

// ---------------------------------------------------------------------------
// Raw read/write
// ---------------------------------------------------------------------------
async function readRaw() {
  // Try localStorage first - it's synchronous and we mirror everything to it
  // on every save, so under Tauri this avoids waiting for plugin-store init
  // (~50-100ms cold) on the first read after navigation. The Tauri store is
  // still consulted as a fallback for first-run-after-clean-install.
  try {
    const raw =
      localStorage.getItem(STORAGE_KEY) || getCookie(STORAGE_KEY) || ""
    if (raw) {
      const parsed = JSON.parse(raw)
      if (parsed && typeof parsed === "object") return parsed
    }
  } catch (e) {
    // Corrupted JSON in localStorage/cookie. We continue to the store
    // fallback below, but warn so a "my login disappeared" report has
    // a console grep target.
    log.warn("[xt:creds] stored entries blob is unparseable:", e)
  }
  const store = await getStore()
  if (store) {
    const v = await store.get(STORAGE_KEY)
    if (v && typeof v === "object") return v
  }
  return null
}

async function writeRaw(data) {
  const store = await getStore()
  const json = JSON.stringify(data)
  if (store) {
    try {
      await store.set(STORAGE_KEY, data)
      await store.save()
    } catch (e) {
      log.error("[xt:creds] plugin-store write failed:", e)
    }
  }
  try {
    localStorage.setItem(STORAGE_KEY, json)
    setCookie(STORAGE_KEY, json)
  } catch (e) {
    log.error("[xt:creds] localStorage/cookie write failed:", e)
  }
  migrationPromise = Promise.resolve(data)
}

// ---------------------------------------------------------------------------
// Migration from the legacy flat keys
// ---------------------------------------------------------------------------
async function readLegacy() {
  const store = await getStore()
  const out = { host: "", port: "", user: "", pass: "" }
  if (store) {
    for (const k of LEGACY_KEYS) {
      out[k] = (await store.get(k)) || ""
    }
  } else {
    for (const k of LEGACY_KEYS) {
      out[k] = localStorage.getItem(`xt_${k}`) || getCookie(`xt_${k}`) || ""
    }
  }
  return out
}

async function clearLegacy() {
  const store = await getStore()
  if (store) {
    for (const k of LEGACY_KEYS) await store.delete(k)
    await store.save()
  }
  try {
    for (const k of LEGACY_KEYS) {
      localStorage.removeItem(`xt_${k}`)
      setCookie(`xt_${k}`, "", -1)
    }
  } catch {}
}

function legacyToEntry({ host, port, user, pass }) {
  if (!host) return null
  try {
    const u = new URL(host)
    const ext = (u.pathname || "").toLowerCase()
    const isM3U = ext.endsWith(".m3u") || ext.endsWith(".m3u8")
    if (/^https?:$/.test(u.protocol) && isM3U && !user && !pass) {
      return {
        _id: uuid(),
        title: u.hostname,
        type: "m3u",
        url: u.href,
        addedAt: Date.now(),
      }
    }
  } catch (e) {
    // legacy `host` wasn't a parseable URL - we fall through to the
    // composeServerUrl path. Warn so a stuck migration is greppable.
    log.warn("[xt:creds] legacy host migration: URL parse failed:", e)
  }

  const serverUrl = composeServerUrl(host, port)
  return {
    _id: uuid(),
    title: hostnameFrom(serverUrl) || "Migrated playlist",
    type: "xtream",
    serverUrl,
    username: user,
    password: pass,
    addedAt: Date.now(),
  }
}

let migrationPromise = null
async function ensureMigrated() {
  if (migrationPromise) return migrationPromise
  migrationPromise = (async () => {
    const existing = await readRaw()
    if (existing && Array.isArray(existing.entries)) return existing
    const legacy = await readLegacy()
    const entry = legacyToEntry(legacy)
    const seed = entry
      ? { entries: [entry], selectedId: entry._id }
      : { entries: [], selectedId: "" }
    if (entry) {
      await writeRaw(seed)
      await clearLegacy()
    }
    return seed
  })()
  return migrationPromise
}

// ---------------------------------------------------------------------------
// Public entries API
// ---------------------------------------------------------------------------
export async function getState() {
  return await ensureMigrated()
}

export async function getEntries() {
  return (await getState()).entries
}

export async function getActiveEntry() {
  const s = await getState()
  return s.entries.find((e) => e._id === s.selectedId) || null
}

export async function addEntry(partial) {
  const s = await getState()
  const entry = {
    _id: uuid(),
    addedAt: Date.now(),
    ...partial,
  }
  let pendingLocalContent = null
  if (entry.type === "xtream") {
    entry.serverUrl = (entry.serverUrl || "").replace(/\/+$/, "")
  } else if (entry.type === "m3u") {
    entry.url = entry.url || ""
  } else if (entry.type === "local-m3u") {
    pendingLocalContent = typeof entry.content === "string" ? entry.content : ""
    delete entry.content // never lives on the main entries blob
    entry.sourceName = entry.sourceName || ""
  }
  entry.epgUrl = typeof entry.epgUrl === "string" ? entry.epgUrl.trim() : ""
  entry.additionalEpgUrls = Array.isArray(entry.additionalEpgUrls)
    ? entry.additionalEpgUrls
        .map((url) => (typeof url === "string" ? url.trim() : ""))
        .filter(Boolean)
    : []
  entry.disableProviderEpg = !!entry.disableProviderEpg
  if (!entry.title) {
    entry.title =
      entry.type === "xtream"
        ? hostnameFrom(entry.serverUrl) || "Untitled"
        : entry.type === "local-m3u"
        ? entry.sourceName || "Local playlist"
        : hostnameFrom(entry.url) || "Untitled"
  }
  if (pendingLocalContent !== null) {
    const { setLocalContent } = await import("./local-content.js")
    await setLocalContent(entry._id, pendingLocalContent)
  }
  const next = {
    entries: [...s.entries, entry],
    selectedId: entry._id, // newly added becomes active
  }
  await writeRaw(next)
  dispatch(EVT_ENTRIES_UPDATED)
  dispatch(EVT_ACTIVE_CHANGED, entry)
  return entry
}

export async function selectEntry(id) {
  const s = await getState()
  if (s.selectedId === id) return
  const e = s.entries.find((x) => x._id === id)
  if (!e) return
  e.lastUsedAt = Date.now()
  await writeRaw({ ...s, selectedId: id })
  dispatch(EVT_ACTIVE_CHANGED, e)
}

export async function removeEntry(id) {
  const s = await getState()
  const removed = s.entries.find((e) => e._id === id)
  const remaining = s.entries.filter((e) => e._id !== id)
  let selectedId = s.selectedId
  if (selectedId === id) selectedId = remaining[0]?._id || ""
  await writeRaw({ entries: remaining, selectedId })
  const { invalidateEntry } = await import("./cache.js")
  invalidateEntry(id)
  const { clearForPlaylist } = await import("./preferences.js")
  clearForPlaylist(id)
  if (removed?.type === "local-m3u") {
    const { deleteLocalContent } = await import("./local-content.js")
    deleteLocalContent(id).catch(() => {})
  }
  dispatch(EVT_ENTRIES_UPDATED)
  dispatch(EVT_ACTIVE_CHANGED, await getActiveEntry())
}

export async function updateEntry(id, patch) {
  const s = await getState()
  const existing = s.entries.find((e) => e._id === id)
  const isLocal = patch?.type === "local-m3u" || existing?.type === "local-m3u"
  const incoming = { ...patch }
  let pendingLocalContent = null
  if (isLocal) {
    if (typeof incoming.content === "string") {
      pendingLocalContent = incoming.content
    }
    delete incoming.content
  }
  const next = s.entries.map((e) => {
    if (e._id !== id) return e
    const merged = { ...e, ...incoming }
    if (isLocal) delete merged.content // keep entries blob small
    if (typeof merged.epgUrl === "string") merged.epgUrl = merged.epgUrl.trim()
    if (Array.isArray(merged.additionalEpgUrls)) {
      merged.additionalEpgUrls = merged.additionalEpgUrls
        .map((url) => (typeof url === "string" ? url.trim() : ""))
        .filter(Boolean)
    }
    if ("disableProviderEpg" in merged) {
      merged.disableProviderEpg = !!merged.disableProviderEpg
    }
    return merged
  })
  if (pendingLocalContent !== null) {
    const { setLocalContent } = await import("./local-content.js")
    await setLocalContent(id, pendingLocalContent)
  }
  await writeRaw({ ...s, entries: next })
  const { invalidateEntry } = await import("./cache.js")
  invalidateEntry(id)
  dispatch(EVT_ENTRIES_UPDATED)
  if (s.selectedId === id) dispatch(EVT_ACTIVE_CHANGED, await getActiveEntry())
}

/**
 * Replace the entire playlist state. Used by the import-settings flow.
 * Caller is responsible for sanitising the input shape before calling.
 * @param {{ entries: any[], selectedId: string }} state
 */
export async function restoreState(state) {
  const safe = {
    entries: Array.isArray(state?.entries) ? state.entries : [],
    selectedId: typeof state?.selectedId === "string" ? state.selectedId : "",
  }
  await writeRaw(safe)
  migrationPromise = Promise.resolve(safe)
  try {
    const { invalidateEntry } = await import("./cache.js")
    for (const e of safe.entries) {
      if (e?._id) invalidateEntry(e._id)
    }
  } catch {}
  dispatch(EVT_ENTRIES_UPDATED)
  dispatch(EVT_ACTIVE_CHANGED, safe.entries.find((e) => e._id === safe.selectedId) || null)
}

/** Force a re-fetch of the active playlist's data.
 *  Keeps the existing cache as a fallback */
export async function refreshActive() {
  const active = await getActiveEntry()
  if (!active) return
  const { warmupActive } = await import("./catalog.js")
  let result = null
  try {
    result = await warmupActive(active._id, { force: true })
  } catch (err) {
    log.warn("[xt:creds] refreshActive: warmupActive threw", err)
  }
  dispatch(EVT_ACTIVE_CHANGED, active)
  if (result?.errors && Object.keys(result.errors).length >= 3) {
    throw new Error("Refresh failed for all kinds")
  }
}

function dispatch(name, detail) {
  try {
    document.dispatchEvent(new CustomEvent(name, { detail }))
  } catch {}
}

// ---------------------------------------------------------------------------
// Back-compat shim: callers that still want flat {host,port,user,pass}.
// ---------------------------------------------------------------------------
export async function loadCreds() {
  const e = await getActiveEntry()
  if (!e) return { host: "", port: "", user: "", pass: "" }
  if (e.type === "m3u") {
    return { host: e.url || "", port: "", user: "", pass: "" }
  }
  if (e.type === "local-m3u") {
    return { host: LOCAL_M3U_SCHEME + e._id, port: "", user: "", pass: "" }
  }
  return {
    host: e.serverUrl || "",
    port: "",
    user: e.username || "",
    pass: e.password || "",
  }
}

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------
export function fmtBase(host, port) {
  if (!host) return ""
  const withScheme = /^https?:\/\//i.test(host) ? host : `http://${host}`
  const trimmed = withScheme.replace(/\/+$/, "")
  const authority = trimmed.replace(/^https?:\/\//i, "").split("/")[0]
  const hasPort = /:\d+$/.test(authority)
  return port && !hasPort ? `${trimmed}:${port}` : trimmed
}

export function safeHttpUrl(u) {
  if (!u) return ""
  try {
    const base =
      typeof location !== "undefined" ? location.href : "http://x/"
    const x = new URL(u, base)
    return /^https?:$/.test(x.protocol) ? x.href : ""
  } catch {
    return ""
  }
}

export function buildApiUrl(creds, action, params = {}) {
  const url = new URL(fmtBase(creds.host, creds.port) + "/player_api.php")
  const search = new URLSearchParams({
    username: creds.user,
    password: creds.pass,
  })
  if (action) search.set("action", action)
  for (const [k, v] of Object.entries(params)) search.set(k, v)
  url.search = search.toString()
  return url.toString()
}

export function isLikelyM3USource(host, user, pass) {
  if (typeof host === "string" && host.startsWith(LOCAL_M3U_SCHEME)) return true
  try {
    const url = new URL(host)
    const ext = (url.pathname || "").toLowerCase()
    const isM3U = ext.endsWith(".m3u") || ext.endsWith(".m3u8")
    return /^https?:$/.test(url.protocol) && isM3U && !user && !pass
  } catch {
    return false
  }
}

/** Returns true when the host string is the local-file sentinel. */
export function isLocalM3UHost(host) {
  return typeof host === "string" && host.startsWith(LOCAL_M3U_SCHEME)
}

/**
 * Read the stored M3U text for a local-m3u entry. `host` is the
 * `xt-local://<id>` sentinel returned by loadCreds(). Returns the empty
 * string if the entry has gone missing. Throws when the underlying IDB
 * read fails so callers don't cache an empty playlist on transient errors.
 *
 * Falls back to a `content` field on the entry itself for backward
 * compatibility with the first version of the feature, which embedded the
 * text on the entry. On hit, that content is migrated into IDB and stripped
 * from the entry so subsequent reads are fast and the entries blob shrinks.
 */
export async function readLocalM3UContent(host) {
  if (!isLocalM3UHost(host)) return ""
  const id = host.slice(LOCAL_M3U_SCHEME.length)
  const { getLocalContent, setLocalContent } = await import("./local-content.js")
  const fromIdb = await getLocalContent(id)
  if (fromIdb === null) {
    throw new Error("local-m3u storage unavailable")
  }
  if (fromIdb) return fromIdb
  const entries = await getEntries()
  const entry = entries.find((e) => e._id === id && e.type === "local-m3u")
  const legacy = typeof entry?.content === "string" ? entry.content : ""
  if (legacy) {
    await setLocalContent(id, legacy)
    updateEntry(id, { content: undefined }).catch(() => {})
  }
  return legacy
}

function hostnameFrom(u) {
  if (!u) return ""
  try {
    return new URL(/^https?:\/\//i.test(u) ? u : `http://${u}`).hostname
  } catch {
    return ""
  }
}

function composeServerUrl(host, port) {
  if (!host) return ""
  const base = fmtBase(host, port)
  return base.replace(/\/+$/, "")
}

// ---------------------------------------------------------------------------
// Form helpers (for /login page)
// ---------------------------------------------------------------------------

export function parseXtreamUrl(input) {
  if (!input) return null
  let url
  try {
    url = new URL(String(input).trim())
  } catch {
    return null
  }
  if (!/^https?:$/.test(url.protocol)) return null
  const username = (url.searchParams.get("username") || "").trim()
  const password = (url.searchParams.get("password") || "").trim()
  if (!username || !password) return null
  // Server URL = origin only (drop player_api.php / get.php / etc.)
  return {
    serverUrl: url.origin,
    username,
    password,
  }
}

/**
 * Hit `get_account_info` and classify the response.
 * @returns {Promise<{ status: "active"|"expired"|"inactive"|"unavailable", expDate?: number, message?: string }>}
 */
export async function testXtreamConnection({ serverUrl, username, password }) {
  if (!serverUrl || !username || !password) {
    return { status: "unavailable", message: "Missing fields" }
  }
  const safe = safeHttpUrl(serverUrl)
  if (!safe) return { status: "unavailable", message: "Bad URL" }
  try {
    const url = buildApiUrl(
      { host: serverUrl, port: "", user: username, pass: password },
      "get_account_info"
    )
    const { providerFetch } = await import("./provider-fetch.js")
    const r = await providerFetch(url)
    if (!r.ok) {
      return {
        status: "unavailable",
        message: `HTTP ${r.status} ${r.statusText}`,
      }
    }
    const data = await r.json().catch(() => null)
    const info = data?.user_info
    if (!info?.status) {
      return { status: "unavailable", message: "No user_info in response" }
    }
    const expSeconds = parseInt(info.exp_date ?? "", 10)
    const expDate = Number.isFinite(expSeconds) ? expSeconds * 1000 : null
    if (info.status !== "Active") return { status: "inactive", expDate }
    if (expDate && expDate < Date.now()) return { status: "expired", expDate }
    return { status: "active", expDate }
  } catch (e) {
    return { status: "unavailable", message: String(e) }
  }
}

/**
 * @returns {Promise<{ status: "active"|"unavailable", count?: number, message?: string }>}
 */
export async function testM3UUrl(url) {
  if (!url) return { status: "unavailable", message: "Missing URL" }
  if (!/^https?:\/\//i.test(url)) {
    return { status: "unavailable", message: "URL must start with http(s)://" }
  }
  try {
    const { providerFetch } = await import("./provider-fetch.js")
    const r = await providerFetch(url)
    if (!r.ok) {
      return {
        status: "unavailable",
        message: `HTTP ${r.status} ${r.statusText}`,
      }
    }
    const text = await r.text()
    const head = text.slice(0, 4096)
    const looksLikeM3U =
      head.includes("#EXTM3U") || /#EXTINF\s*:/i.test(head)
    if (!looksLikeM3U) {
      return {
        status: "unavailable",
        message: "Response doesn't look like an M3U playlist.",
      }
    }
    const matches = text.match(/#EXTINF\s*:/gi)
    return { status: "active", count: matches ? matches.length : 0 }
  } catch (e) {
    return { status: "unavailable", message: String(e?.message || e) }
  }
}

// Text and timing helpers used to live here. They moved to dedicated files
// so creds.js doesn't double as the catch-all utility module.
//   normalize, scoreNormMatch -> @/scripts/lib/text.js
//   debounce                   -> @/scripts/lib/debounce.js
