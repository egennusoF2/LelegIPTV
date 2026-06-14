/**
 * Tiny logging boundary for browser-side code.
 *
 * `error` and `warn` always reach the console so production users can attach
 * stack traces to a bug report. `info` / `debug` / `log` are gated to dev so
 * they don't pollute the console in shipping builds.
 *
 * Future: route through `@tauri-apps/plugin-log` when the plugin is installed
 * on the Rust side - the JS shim accepts the same arg shape, so swapping in is
 * a one-file change here.
 *
 * Existing call sites keep their `[xt:component]` prefix as the first arg.
 */

const isDev = Boolean(import.meta.env?.DEV)

const isTauri =
    typeof window !== "undefined" &&
    (!!(window as Window & { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ ||
        !!(window as Window & { __TAURI__?: unknown }).__TAURI__)

/** Shipping Tauri builds: persist [xt:*] lines via tauri-plugin-log (see ~/Library/Logs/...). */
const tauriLogs = isTauri && !isDev

type LogFn = (...args: unknown[]) => void
const noop: LogFn = () => {}

let tauriLogReady: Promise<{
    error: (msg: string) => Promise<void>
    warn: (msg: string) => Promise<void>
    info: (msg: string) => Promise<void>
    debug: (msg: string) => Promise<void>
} | null> | null = null

function getTauriLog() {
    if (!tauriLogs) return null
    if (!tauriLogReady) {
        tauriLogReady = import("@tauri-apps/plugin-log")
            .then((mod) => mod)
            .catch(() => null)
    }
    return tauriLogReady
}

function formatArgs(args: unknown[]): string {
    return args
        .map((a) => {
            if (a == null) return String(a)
            if (typeof a === "string") return a
            try {
                return JSON.stringify(a)
            } catch {
                return String(a)
            }
        })
        .join(" ")
}

function mirror(
    level: "error" | "warn" | "info" | "debug" | "log",
    consoleFn: LogFn,
    ...args: unknown[]
): void {
    consoleFn(...args)
    if (!tauriLogs) return
    void getTauriLog().then((plugin) => {
        if (!plugin) return
        const line = formatArgs(args)
        const send =
            level === "log"
                ? plugin.info
                : level === "debug"
                  ? plugin.debug
                  : plugin[level]
        void send(line).catch(() => {})
    })
}

export const log: {
    error: LogFn
    warn: LogFn
    info: LogFn
    debug: LogFn
    log: LogFn
} = {
    error: (...args) => mirror("error", console.error.bind(console), ...args),
    warn: (...args) => mirror("warn", console.warn.bind(console), ...args),
    info: isDev || tauriLogs
        ? (...args) => mirror("info", console.info.bind(console), ...args)
        : noop,
    debug: isDev || tauriLogs
        ? (...args) => mirror("debug", console.debug.bind(console), ...args)
        : noop,
    log: isDev || tauriLogs
        ? (...args) => mirror("log", console.log.bind(console), ...args)
        : noop,
}

const SENSITIVE_PARAMS = /(\b(?:username|user|password|pass|token|auth|key|api_key|apikey)=)([^&#\s]*)/gi
const SENSITIVE_XTREAM_PATH = /(\/(?:live|movie|series)\/)([^/?#\s]+)(\/)([^/?#\s]+)(\/)/gi
const SENSITIVE_ENCODED_XTREAM_PATH =
    /(%2f(?:live|movie|series)%2f)([^%&#\s]+)(%2f)([^%&#\s]+)(%2f)/gi

/**
 * Strip credential-looking query params from any URL or URL-bearing string
 * before it goes to log.error / log.warn. `log.error` is unconditional in
 * production builds (see `error` above). Xtream URLs can carry credentials in
 * either query params or path segments (`/movie/user/pass/id.ext`).
 */
export function redactUrl(input: unknown): string {
    if (input == null) return ""
    const text = typeof input === "string" ? input : String(input)
    return text
        .replace(SENSITIVE_PARAMS, (_match, prefix) => `${prefix}***`)
        .replace(SENSITIVE_XTREAM_PATH, (_match, prefix, _user, sep, _pass, suffix) => (
            `${prefix}***${sep}***${suffix}`
        ))
        .replace(SENSITIVE_ENCODED_XTREAM_PATH, (_match, prefix, _user, sep, _pass, suffix) => (
            `${prefix}***${sep}***${suffix}`
        ))
}
