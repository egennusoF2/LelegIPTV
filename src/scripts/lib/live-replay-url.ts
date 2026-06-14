/** Parse optional catchup window from `/livetv?channel=&catchupStart=&catchupStop=`. */

export interface LiveReplayWindow {
  start: number
  stop: number
}

export function parseReplayWindowFromSearchParams(
  params: URLSearchParams,
): LiveReplayWindow | null {
  const rawStart = params.get("catchupStart")
  const rawStop = params.get("catchupStop")
  if (rawStart == null || rawStop == null || rawStart === "" || rawStop === "") {
    return null
  }
  const start = Number(rawStart)
  const stop = Number(rawStop)
  if (!Number.isFinite(start) || !Number.isFinite(stop)) return null
  if (stop <= start) return null
  return { start, stop }
}
