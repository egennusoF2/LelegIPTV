import { fmtBase } from "@/scripts/lib/creds.js"

export interface CatchupChannel {
  id: number | string
  url?: string | null
  catchup?: string | null
  catchupDays?: number | null
  catchupSource?: string | null
}

export interface CatchupProgramme {
  start: number
  stop: number
}

export interface CatchupCreds {
  host?: string
  port?: string
  user?: string
  pass?: string
  liveContainer?: string | null
}

const DEFAULT_CATCHUP_DAYS = 7

function preferredLiveContainer(creds: CatchupCreds): "hls" | "ts" {
  const configured = String(creds.liveContainer || "").trim().toLowerCase()
  if (configured === "ts" || configured === "mpegts") return "ts"
  if (configured === "hls" || configured === "m3u8") return "hls"
  return "hls"
}

function seconds(ms: number): number {
  return Math.floor(ms / 1000)
}

function durationMinutes(programme: CatchupProgramme): number {
  return Math.max(1, Math.ceil((programme.stop - programme.start) / 60_000))
}

function formatXtreamStart(ts: number): string {
  const d = new Date(ts)
  const pad = (value: number) => String(value).padStart(2, "0")
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}:` +
    `${pad(d.getHours())}-${pad(d.getMinutes())}`
  )
}

function appendQuery(url: string, query: string): string {
  return `${url}${url.includes("?") ? "&" : "?"}${query}`
}

function replaceCatchupPlaceholders(
  template: string,
  programme: CatchupProgramme,
): string {
  const start = seconds(programme.start)
  const stop = seconds(programme.stop)
  const duration = Math.max(1, stop - start)
  const minutes = durationMinutes(programme)
  const now = seconds(Date.now())
  const replacements: Record<string, string | number> = {
    start,
    end: stop,
    stop,
    utc: start,
    lutc: now,
    timestamp: now,
    duration,
    "duration-minutes": minutes,
    offset: start,
  }
  return template.replace(/\$\{([^}]+)\}|\{([^}]+)\}/g, (match, a, b) => {
    const key = String(a || b || "").trim().toLowerCase()
    return replacements[key] == null ? match : String(replacements[key])
  })
}

export function channelHasCatchup(channel: CatchupChannel | null | undefined): boolean {
  if (!channel) return false
  const mode = String(channel.catchup || "").trim().toLowerCase()
  return (
    !!channel.catchupSource ||
    !!channel.catchupDays ||
    mode === "xtream" ||
    mode === "append" ||
    mode === "default" ||
    mode === "shift" ||
    mode === "flussonic"
  )
}

export function canReplayProgramme(
  channel: CatchupChannel | null | undefined,
  programme: CatchupProgramme | null | undefined,
  now = Date.now(),
): boolean {
  if (!channelHasCatchup(channel) || !programme) return false
  if (!Number.isFinite(programme.start) || !Number.isFinite(programme.stop)) return false
  if (programme.stop > now || programme.stop <= programme.start) return false
  const days = Number(channel?.catchupDays)
  const windowDays = Number.isFinite(days) && days > 0 ? days : DEFAULT_CATCHUP_DAYS
  return programme.start >= now - windowDays * 24 * 60 * 60 * 1000
}

export function buildCatchupStreamUrl(
  channel: CatchupChannel,
  programme: CatchupProgramme,
  creds: CatchupCreds = {},
): string | null {
  if (!canReplayProgramme(channel, programme)) return null
  if (channel.catchupSource) {
    return replaceCatchupPlaceholders(channel.catchupSource, programme)
  }

  const mode = String(channel.catchup || "").trim().toLowerCase()
  if (channel.url && (mode === "append" || mode === "default" || mode === "shift" || mode === "flussonic" || !!channel.catchupDays)) {
    return appendQuery(
      channel.url,
      `utc=${seconds(programme.start)}&lutc=${seconds(Date.now())}`,
    )
  }

  if (mode === "xtream" && creds.host && creds.user && creds.pass) {
    const ext = preferredLiveContainer(creds) === "ts" ? ".ts" : ".m3u8"
    return (
      fmtBase(creds.host, creds.port || "") +
      "/timeshift/" +
      encodeURIComponent(creds.user) +
      "/" +
      encodeURIComponent(creds.pass) +
      "/" +
      durationMinutes(programme) +
      "/" +
      encodeURIComponent(formatXtreamStart(programme.start)) +
      "/" +
      encodeURIComponent(String(channel.id)) +
      ext
    )
  }

  return null
}
