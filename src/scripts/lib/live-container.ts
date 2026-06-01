export type LiveContainer = "hls" | "ts"

export interface LiveContainerCreds {
  liveContainer?: string | null
}

/** Xtream live container for embedded players (HLS unless user chose TS). */
export function preferredLiveContainer(
  creds?: LiveContainerCreds | null,
): LiveContainer {
  const configured = String(creds?.liveContainer || "").trim().toLowerCase()
  if (configured === "ts" || configured === "mpegts") return "ts"
  if (configured === "hls" || configured === "m3u8") return "hls"
  return "hls"
}

export function liveStreamExtension(container: LiveContainer): ".m3u8" | ".ts" {
  return container === "ts" ? ".ts" : ".m3u8"
}

/** Whether MPEG-TS over MSE is likely to work (codec / MSE support). */
export function mpegtsMseLikelySupported(): boolean {
  if (typeof MediaSource === "undefined") return false
  try {
    return MediaSource.isTypeSupported(
      'video/mp2t; codecs="avc1.42E01E,mp4a.40.2"',
    )
  } catch {
    return false
  }
}

/** Whether MSE can decode a given audio codec in fMP4 (e.g. E-AC-3 in IPTV TS). */
export function mseAudioCodecSupported(codec: string): boolean {
  if (typeof MediaSource === "undefined") return false
  try {
    return MediaSource.isTypeSupported(`audio/mp4;codecs="${codec}"`)
  } catch {
    return false
  }
}

/** Auto TS fallback is only useful when the user chose TS or MSE can play typical IPTV audio. */
export function allowAutoTsFallback(creds?: LiveContainerCreds | null): boolean {
  if (preferredLiveContainer(creds) === "ts") return true
  return mseAudioCodecSupported("ec-3")
}
