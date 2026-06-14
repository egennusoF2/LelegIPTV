/** Cache-bust Xtream live URLs so panels return a fresh HLS window (not stale segments). */

export function bustLiveStreamUrl(url: string): string {
  if (!url) return url
  try {
    const parsed = new URL(url)
    parsed.searchParams.set("_xt", String(Date.now()))
    return parsed.href
  } catch {
    const sep = url.includes("?") ? "&" : "?"
    return `${url}${sep}_xt=${Date.now()}`
  }
}
