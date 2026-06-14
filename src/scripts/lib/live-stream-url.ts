import { unwrapStreamProxyUrl } from "@/scripts/lib/stream-proxy"

export type LiveStreamKind = "hls" | "ts" | "other"

/** Resolve Xtream live kind from a direct or `/__stream?url=` playback URL. */
export function upstreamLiveStreamKind(src: string | null | undefined): LiveStreamKind {
  const upstream = unwrapStreamProxyUrl(String(src || ""))
  if (/\.m3u8(?:[?#&]|$)/i.test(upstream)) return "hls"
  if (/\.ts(?:[?#&]|$)/i.test(upstream)) return "ts"
  return "other"
}

export function isUpstreamLiveHls(src: string | null | undefined): boolean {
  return upstreamLiveStreamKind(src) === "hls"
}

export function isUpstreamLiveTs(src: string | null | undefined): boolean {
  return upstreamLiveStreamKind(src) === "ts"
}

/** Cache-bust the upstream Xtream URL (not the loopback proxy wrapper). */
export function bustUpstreamLiveUrl(src: string): string {
  const upstream = unwrapStreamProxyUrl(src)
  if (!upstream) return src
  try {
    const parsed = new URL(upstream)
    parsed.searchParams.set("_xt", String(Date.now()))
    return parsed.href
  } catch {
    const sep = upstream.includes("?") ? "&" : "?"
    return `${upstream}${sep}_xt=${Date.now()}`
  }
}
