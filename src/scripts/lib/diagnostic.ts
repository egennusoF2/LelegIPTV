// Multi-step connection diagnostic. Two entry points share the same logic:
//   - Login page: progressive disclosure under the Test result.
//   - Settings page: per-playlist "Run diagnostic" button inside the health panel.
//
// Xtream pipeline (4 steps):
//   1. Authenticate (get_account_info) - blocking; reach + creds + account info
//   2. Live channels   (get_live_streams,  parallel after auth)
//   3. Movies          (get_vod_streams,   parallel after auth)
//   4. Series          (get_series,        parallel after auth)
//
// Each catalogue probe streams its result as soon as it lands rather than
// waiting for the slowest, so on a typical run with 1s/4s/10s timings the
// user sees Live at 1s and Movies at 4s instead of both appearing together
// when Series finishes 10s in.
//
// M3U pipeline (2 steps):
//   1. Fetch playlist
//   2. Parse + count #EXTINF entries
//
// Step messages route through the same `classifyError` taxonomy the simple
// Test button uses, so users see the same wording across both surfaces.
// Auth failure stops downstream steps - no point probing catalogue
// endpoints with bad creds.

import { t } from "@/scripts/lib/i18n.js"
import { buildApiUrl, safeHttpUrl } from "@/scripts/lib/creds.js"
import { classifyError } from "@/scripts/lib/provider-error.js"

export type StepStatus = "pass" | "warn" | "fail" | "skip"

export interface DiagnosticStep {
  /** Translation key for the step label (e.g. "diagnostic.step.reach"). */
  labelKey: string
  status: StepStatus
  latencyMs?: number
  /** Pre-translated detail line, optional. */
  detail?: string
  /** Item count, when the step produces a count (used in the detail line). */
  count?: number
  /** classifyError kind, when the step failed. */
  reason?: string
  /** HTTP status code, when present. */
  httpStatus?: number
}

export type DiagnosticVerdict = "ok" | "warn" | "fail" | "running"

export interface DiagnosticResult {
  steps: DiagnosticStep[]
  verdict: DiagnosticVerdict
  /** Pre-translated verdict line. */
  verdictMessage: string
}

interface XtreamCreds {
  serverUrl: string
  username: string
  password: string
}

const STEP_TIMEOUT_MS = 12_000

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout")), ms)
    promise.then(
      (value) => {
        clearTimeout(timer)
        resolve(value)
      },
      (error) => {
        clearTimeout(timer)
        reject(error)
      }
    )
  })
}

async function jsonCount(response: Response, keys: string[]): Promise<number> {
  const data = await response.json()
  if (Array.isArray(data)) return data.length
  for (const key of keys) {
    const value = (data as any)?.[key]
    if (Array.isArray(value)) return value.length
  }
  // Server replied with 2xx + valid JSON, but the body isn't an array under
  // any expected key. Most often this means an Xtream panel returned
  // `{"error": "..."}` or a status object instead of the catalogue. Surface
  // as bad_response so the caller flags the step "warn" - reporting "0
  // entries" with a pass icon would be actively misleading.
  throw new Error("unexpected response shape")
}

/**
 * Format step latency for display. Sub-second results stay in ms ("245ms");
 * anything longer rolls up to one-decimal seconds ("1.4s", "10.2s") so the
 * eye doesn't have to count four digits at a glance.
 */
function fmtLatency(ms: number): string {
  if (ms < 1000) return `${ms}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

export interface DiagnosticRunOptions {
  /**
   * Fires after each step completes with the current step list. Used by the
   * UI to render progress without waiting for the whole wizard to finish.
   * Not called once more with the final list - the caller already has the
   * resolved promise for that.
   */
  onProgress?: (steps: DiagnosticStep[]) => void
}

/**
 * Run the full Xtream diagnostic. Steps run sequentially up to auth (no
 * point probing endpoints with bad creds), then catalogue endpoints run in
 * parallel for the remaining steps.
 *
 * Reach + auth are intentionally collapsed into one step: if the
 * authenticate call returns, we reached the server; if classifyError says
 * `unreachable` / `timeout`, we didn't. A separate bare-GET probe to
 * `/player_api.php` produced false warnings because several Xtream panels
 * misuse HTTP 511 ("Network Authentication Required") when the endpoint is
 * hit without query params.
 */
export async function runXtreamDiagnostic(
  creds: XtreamCreds,
  options: DiagnosticRunOptions = {}
): Promise<DiagnosticResult> {
  const steps: DiagnosticStep[] = []
  const { providerFetch } = await import("@/scripts/lib/provider-fetch.js")
  const pushStep = (step: DiagnosticStep) => {
    steps.push(step)
    options.onProgress?.(steps.slice())
  }

  const base = safeHttpUrl(creds.serverUrl)
  if (!base) {
    pushStep({ labelKey: "diagnostic.step.auth", status: "fail", detail: t("diagnostic.detail.invalidUrl") })
    return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.invalidUrl") }
  }

  const apiCreds = {
    host: creds.serverUrl,
    port: "",
    user: creds.username,
    pass: creds.password,
  }

  // Step 1: authenticate. The roundtrip latency doubles as the reach
  // measurement, and classifyError tells us whether the failure was
  // connectivity or auth. If auth fails we stop - no point hammering
  // catalogue endpoints with bad creds.
  const authStart = Date.now()
  try {
    const url = buildApiUrl(apiCreds, "get_account_info")
    const response = await withTimeout(providerFetch(url), STEP_TIMEOUT_MS)
    const latency = Date.now() - authStart
    if (!response.ok) {
      const classified = classifyError({ response })
      pushStep({
        labelKey: "diagnostic.step.auth",
        status: "fail",
        latencyMs: latency,
        detail: t(`providerError.classify.${classified.kind}`, { status: String(classified.httpStatus ?? "") }),
        reason: classified.kind,
        httpStatus: classified.httpStatus,
      })
      return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.authFailed") }
    }
    let data: any
    try {
      data = await response.json()
    } catch {
      pushStep({
        labelKey: "diagnostic.step.auth",
        status: "fail",
        latencyMs: latency,
        detail: t("providerError.classify.bad_response"),
        reason: "bad_response",
      })
      return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.badResponse") }
    }
    const info = data?.user_info
    if (info && (info.auth === 0 || info.auth === "0")) {
      pushStep({
        labelKey: "diagnostic.step.auth",
        status: "fail",
        latencyMs: latency,
        detail: t("providerError.classify.auth_rejected"),
        reason: "auth_rejected",
      })
      return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.authRejected") }
    }
    if (!info?.status) {
      pushStep({
        labelKey: "diagnostic.step.auth",
        status: "fail",
        latencyMs: latency,
        detail: t("providerError.classify.bad_response"),
        reason: "bad_response",
      })
      return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.badResponse") }
    }
    const maxCons = info.max_connections ?? "-"
    const activeCons = info.active_cons ?? "-"
    const accountStatus = String(info.status)
    const isActive = accountStatus === "Active"
    pushStep({
      labelKey: "diagnostic.step.auth",
      status: isActive ? "pass" : "warn",
      latencyMs: latency,
      detail: t("diagnostic.detail.accountInfo", {
        status: accountStatus,
        active: String(activeCons),
        max: String(maxCons),
      }),
    })
    if (!isActive) {
      return {
        steps,
        verdict: "warn",
        verdictMessage: t("diagnostic.verdict.accountInactive", { status: accountStatus }),
      }
    }
  } catch (error) {
    const classified = classifyError({ error })
    pushStep({
      labelKey: "diagnostic.step.auth",
      status: "fail",
      latencyMs: Date.now() - authStart,
      detail: t(`providerError.classify.${classified.kind}`),
      reason: classified.kind,
    })
    return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.authFailed") }
  }

  // Steps 2-4
  const probeStep = async (
    labelKey: string,
    action: string,
    countKeys: string[]
  ): Promise<void> => {
    const started = Date.now()
    try {
      const response = await withTimeout(
        providerFetch(buildApiUrl(apiCreds, action)),
        STEP_TIMEOUT_MS
      )
      const latency = Date.now() - started
      if (!response.ok) {
        const classified = classifyError({ response })
        pushStep({
          labelKey,
          status: "warn",
          latencyMs: latency,
          detail: t(`providerError.classify.${classified.kind}`, { status: String(classified.httpStatus ?? "") }),
          reason: classified.kind,
          httpStatus: classified.httpStatus,
        })
        return
      }
      try {
        const count = await jsonCount(response, countKeys)
        pushStep({
          labelKey,
          status: "pass",
          latencyMs: latency,
          count,
          detail: t("diagnostic.detail.count", { count: count.toLocaleString() }),
        })
      } catch {
        pushStep({
          labelKey,
          status: "warn",
          latencyMs: latency,
          detail: t("providerError.classify.bad_response"),
          reason: "bad_response",
        })
      }
    } catch (error) {
      const classified = classifyError({ error })
      pushStep({
        labelKey,
        status: "warn",
        latencyMs: Date.now() - started,
        detail: t(`providerError.classify.${classified.kind}`),
        reason: classified.kind,
      })
    }
  }

  await Promise.all([
    probeStep("diagnostic.step.live", "get_live_streams", ["streams", "results"]),
    probeStep("diagnostic.step.vod", "get_vod_streams", ["movies", "results"]),
    probeStep("diagnostic.step.series", "get_series", ["series", "results"]),
  ])

  // Verdict: all-pass → ok. Auth OK but any catalogue step warn → warn
  // (partial outage, the user can still play what's reachable). Anything
  // worse than that already returned earlier.
  const anyWarn = steps.some((step) => step.status === "warn")
  return {
    steps,
    verdict: anyWarn ? "warn" : "ok",
    verdictMessage: anyWarn
      ? t("diagnostic.verdict.partial")
      : t("diagnostic.verdict.allGood"),
  }
}

export async function runM3UDiagnostic(
  url: string,
  options: DiagnosticRunOptions = {}
): Promise<DiagnosticResult> {
  const steps: DiagnosticStep[] = []
  const pushStep = (step: DiagnosticStep) => {
    steps.push(step)
    options.onProgress?.(steps.slice())
  }

  const trimmed = String(url || "").trim()
  if (!trimmed || !/^https?:\/\//i.test(trimmed)) {
    pushStep({
      labelKey: "diagnostic.step.fetch",
      status: "fail",
      detail: t("diagnostic.detail.invalidUrl"),
    })
    return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.invalidUrl") }
  }

  const { providerFetch } = await import("@/scripts/lib/provider-fetch.js")

  const fetchStart = Date.now()
  let text = ""
  try {
    const response = await withTimeout(providerFetch(trimmed), STEP_TIMEOUT_MS)
    const latency = Date.now() - fetchStart
    if (!response.ok) {
      const classified = classifyError({ response })
      pushStep({
        labelKey: "diagnostic.step.fetch",
        status: "fail",
        latencyMs: latency,
        detail: t(`providerError.classify.${classified.kind}`, { status: String(classified.httpStatus ?? "") }),
        reason: classified.kind,
        httpStatus: classified.httpStatus,
      })
      return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.fetchFailed") }
    }
    text = await response.text()
    pushStep({
      labelKey: "diagnostic.step.fetch",
      status: "pass",
      latencyMs: latency,
      detail: t("diagnostic.detail.fetchOk", { status: String(response.status) }),
    })
  } catch (error) {
    const classified = classifyError({ error })
    pushStep({
      labelKey: "diagnostic.step.fetch",
      status: "fail",
      latencyMs: Date.now() - fetchStart,
      detail: t(`providerError.classify.${classified.kind}`),
      reason: classified.kind,
    })
    return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.fetchFailed") }
  }

  const parseStart = Date.now()
  const head = text.slice(0, 4096)
  const looksLikeM3U = head.includes("#EXTM3U") || /#EXTINF\s*:/i.test(head)
  if (!looksLikeM3U) {
    pushStep({
      labelKey: "diagnostic.step.parse",
      status: "fail",
      latencyMs: Date.now() - parseStart,
      detail: t("providerError.classify.bad_response"),
      reason: "bad_response",
    })
    return { steps, verdict: "fail", verdictMessage: t("diagnostic.verdict.badResponse") }
  }
  const matches = text.match(/#EXTINF\s*:/gi)
  const count = matches ? matches.length : 0
  pushStep({
    labelKey: "diagnostic.step.parse",
    status: "pass",
    latencyMs: Date.now() - parseStart,
    count,
    detail: t("diagnostic.detail.count", { count: count.toLocaleString() }),
  })

  return { steps, verdict: "ok", verdictMessage: t("diagnostic.verdict.allGood") }
}

/**
 * Render a diagnostic result into a container. Replaces existing children
 * so the caller can call this multiple times (e.g. after rerunning).
 *
 * Output structure:
 *   <header> verdict icon + verdict message
 *   <ul>     one <li> per step: icon, label, latency, detail
 */
export function renderDiagnosticInto(
  container: HTMLElement,
  result: DiagnosticResult
): void {
  const previousVerdict = container.dataset.diagnosticVerdict
  const isSettlement =
    previousVerdict === "running" && result.verdict !== "running"
  container.dataset.diagnosticVerdict = result.verdict

  container.replaceChildren()
  // Strip every class this helper owns (palette + visual scaffolding) so
  // re-rendering doesn't pile them up, but leave anything else the caller
  // attached - notably outer spacing like `mt-3` that controls the gap
  // between this panel and the buttons above it.
  const ownedClasses = [
    "flex",
    "flex-col",
    "gap-2.5",
    "rounded-xl",
    "border",
    "px-3.5",
    "py-3",
    "text-sm",
    "leading-relaxed",
    "border-ok/40",
    "bg-ok/5",
    "border-warn/40",
    "bg-warn/5",
    "border-line",
    "bg-surface",
    "border-bad/40",
    "bg-bad/5",
    "text-fg-2",
  ]
  for (const c of ownedClasses) container.classList.remove(c)
  container.classList.add(
    "flex",
    "flex-col",
    "gap-2.5",
    "rounded-xl",
    "border",
    "px-3.5",
    "py-3",
    "text-sm",
    "leading-relaxed",
    "transition-colors",
    "duration-300"
  )
  let verdictTextClass = "text-fg"
  if (result.verdict === "ok") {
    container.classList.add("border-ok/40", "bg-ok/5")
    verdictTextClass = "text-ok"
  } else if (result.verdict === "warn") {
    container.classList.add("border-warn/40", "bg-warn/5")
    verdictTextClass = "text-warn"
  } else if (result.verdict === "running") {
    container.classList.add("border-line", "bg-surface")
    verdictTextClass = "text-fg-2"
  } else {
    container.classList.add("border-bad/40", "bg-bad/5")
    verdictTextClass = "text-bad"
  }

  const verdictRow = document.createElement("div")
  verdictRow.className = `flex items-center gap-2 font-semibold text-sm transition-colors duration-300 ${verdictTextClass}`
  const verdictIcon = document.createElement("span")
  verdictIcon.setAttribute("aria-hidden", "true")
  verdictIcon.className =
    "shrink-0 inline-flex items-center justify-center size-5 text-base tabular-nums leading-none " +
    (result.verdict === "running"
      ? "diagnostic-spinner"
      : isSettlement
      ? "diagnostic-verdict-settle"
      : "")
  verdictIcon.textContent =
    result.verdict === "ok"
      ? "✓"
      : result.verdict === "warn"
      ? "!"
      : result.verdict === "running"
      ? "⋯"
      : "✗"
  const verdictText = document.createElement("span")
  verdictText.textContent = result.verdictMessage
  verdictRow.append(verdictIcon, verdictText)
  container.appendChild(verdictRow)

  const list = document.createElement("ul")
  list.className = "flex flex-col gap-2 pl-0.5"
  for (const step of result.steps) {
    const item = document.createElement("li")
    item.className = "flex items-start gap-2 text-xs"
    const iconEl = document.createElement("span")
    iconEl.setAttribute("aria-hidden", "true")
    iconEl.className =
      "shrink-0 inline-flex items-center justify-center size-4 text-xs leading-none tabular-nums " +
      (step.status === "pass"
        ? "text-ok"
        : step.status === "warn"
        ? "text-warn"
        : step.status === "fail"
        ? "text-bad"
        : "text-fg-3")
    iconEl.textContent =
      step.status === "pass"
        ? "✓"
        : step.status === "warn"
        ? "!"
        : step.status === "fail"
        ? "✗"
        : "·"
    const body = document.createElement("div")
    body.className = "min-w-0 flex-1 text-fg"
    const labelRow = document.createElement("div")
    labelRow.className = "flex items-baseline justify-between gap-2"
    const label = document.createElement("span")
    label.className = "font-medium truncate"
    label.textContent = t(step.labelKey)
    labelRow.appendChild(label)
    if (step.latencyMs != null) {
      const latency = document.createElement("span")
      latency.className = "shrink-0 text-2xs text-fg-3 tabular-nums"
      latency.textContent = fmtLatency(step.latencyMs)
      labelRow.appendChild(latency)
    }
    body.appendChild(labelRow)
    if (step.detail) {
      const detail = document.createElement("div")
      detail.className = "mt-1 text-2xs text-fg-3 leading-relaxed"
      detail.textContent = step.detail
      body.appendChild(detail)
    }
    item.append(iconEl, body)
    list.appendChild(item)
  }
  container.appendChild(list)
}
