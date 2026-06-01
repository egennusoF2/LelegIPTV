import { log } from "@/scripts/lib/log.js"
import { mseAudioCodecSupported } from "@/scripts/lib/live-container"

const PREFER_AUDIO_RE = /mp4a|aac|mpeg|mp3|opus/i
const AVOID_AUDIO_RE = /\b(ec-3|eac3|eac-3|ac-3|ac3|dts)\b/i
const VIDEO_CODEC_RE = /^avc|^hev|^hvc|^mp4v|^vp9|^av01/i

export function ensureVideoAudible(
  video: HTMLVideoElement,
  art?: { muted?: boolean; volume?: number } | null,
): void {
  video.muted = false
  if (!video.volume || video.volume < 0.05) video.volume = 1
  if (art) {
    art.muted = false
    if (!art.volume || art.volume < 0.05) art.volume = 1
  }
}

function trackLabel(track: {
  codec?: string
  name?: string
  lang?: string
  groupId?: string
}): string {
  return `${track.codec || ""} ${track.name || ""} ${track.lang || ""} ${track.groupId || ""}`.toLowerCase()
}

export function getCurrentLevelCodecString(hls: {
  levels?: Array<{ codecs?: string; audioCodec?: string }>
  currentLevel?: number
}): string {
  const levels = hls.levels || []
  if (!levels.length) return ""
  const idx =
    hls.currentLevel != null && hls.currentLevel >= 0 ? hls.currentLevel : 0
  const level = levels[idx] || levels[0]
  return [level?.codecs, level?.audioCodec].filter(Boolean).join(",")
}

/** True when the active variant includes a muxed AAC/MP3/Opus audio codec. */
export function levelCodecsHaveMuxedAudio(codecs?: string | null): boolean {
  if (!codecs) return true
  const tokens = codecs
    .split(/[,;\s]+/)
    .map((t) => t.trim())
    .filter(Boolean)
  const hasVideo = tokens.some((t) => VIDEO_CODEC_RE.test(t))
  if (!hasVideo) return true
  return tokens.some((t) => PREFER_AUDIO_RE.test(t))
}

export function pickBestAudioTrackIndex(hls: {
  audioTracks?: Array<{
    codec?: string
    name?: string
    lang?: string
    groupId?: string
  }>
  levels?: Array<{ codecs?: string; audioCodec?: string }>
  currentLevel?: number
}): number {
  const tracks = hls.audioTracks
  if (!Array.isArray(tracks) || tracks.length === 0) return -1

  const muxedOk = levelCodecsHaveMuxedAudio(getCurrentLevelCodecString(hls))

  for (let i = 0; i < tracks.length; i++) {
    const label = trackLabel(tracks[i])
    if (AVOID_AUDIO_RE.test(label)) continue
    if (PREFER_AUDIO_RE.test(label)) return i
  }

  if (muxedOk) return -1
  return -1
}

/** Keep playback on muxed audio unless the active alternate is AAC. */
export function enforceMuxedHlsAudio(hls: {
  audioTrack: number
  audioTracks?: Array<{ codec?: string; name?: string; lang?: string; groupId?: string }>
  levels?: Array<{ codecs?: string; audioCodec?: string }>
  currentLevel?: number
}): boolean {
  const tracks = hls.audioTracks || []
  const current = hls.audioTrack
  const muxedOk = levelCodecsHaveMuxedAudio(getCurrentLevelCodecString(hls))

  if (!muxedOk && tracks.length > 0) {
    const best = pickBestAudioTrackIndex(hls)
    if (best >= 0 && current !== best) {
      hls.audioTrack = best
      log.log("[xt:player] HLS audio: video-only variant, using alternate", best)
      return true
    }
    return false
  }

  if (tracks.length === 0) {
    if (current !== -1) {
      hls.audioTrack = -1
      return true
    }
    return false
  }

  if (current === -1) return false

  const active = tracks[current]
  const label = active ? trackLabel(active) : ""
  if (AVOID_AUDIO_RE.test(label) || !PREFER_AUDIO_RE.test(label)) {
    hls.audioTrack = -1
    log.log("[xt:player] HLS audio forced to muxed (alternate unsupported)", {
      from: current,
      label,
    })
    return true
  }
  return false
}

export function codecsFromHlsManifest(data: {
  levels?: Array<{ codecs?: string; audioCodec?: string }>
  audioTracks?: Array<{ codec?: string }>
}): string {
  const parts: string[] = []
  for (const level of data.levels || []) {
    if (level.codecs) parts.push(level.codecs)
    if (level.audioCodec) parts.push(level.audioCodec)
  }
  for (const track of data.audioTracks || []) {
    if (track.codec) parts.push(track.codec)
  }
  return parts.join(",")
}

export function detectNoPlayableHlsAudio(hls: {
  levels?: Array<{ codecs?: string; audioCodec?: string }>
  audioTracks?: Array<{ codec?: string; name?: string; lang?: string; groupId?: string }>
  currentLevel?: number
}): { blocked: boolean; reason?: string; codecs?: string } {
  const codecs = codecsFromHlsManifest({
    levels: hls.levels,
    audioTracks: hls.audioTracks,
  })
  const muxedOk = levelCodecsHaveMuxedAudio(getCurrentLevelCodecString(hls))

  if (muxedOk) {
    const hasAac = PREFER_AUDIO_RE.test(codecs)
    const needsAc3 = /\b(ac-3|ac3|ec-3|eac3|eac-3)\b/i.test(codecs)
    if (needsAc3 && !hasAac) {
      if (!mseAudioCodecSupported("ac-3") && !mseAudioCodecSupported("ec-3")) {
        return { blocked: true, reason: "muxed-ac3-only", codecs }
      }
    }
    return { blocked: false, codecs }
  }

  const best = pickBestAudioTrackIndex(hls)
  if (best >= 0) return { blocked: false, codecs }

  if ((hls.audioTracks || []).length === 0) {
    return { blocked: true, reason: "video-only-no-audio-group", codecs }
  }
  return { blocked: true, reason: "no-aac-alternate", codecs }
}

export function notifyIfMpegtsAudioCodecUnsupported(codec: string): void {
  if (!codec) return
  notifyIfAudioCodecUnsupported(codec)
}

export function notifyIfAudioCodecUnsupported(codecs: string): void {
  if (!codecs) return
  const needsEc3 = /\b(ec-3|eac3|eac-3)\b/i.test(codecs)
  const needsAc3 = /\b(ac-3|ac3)\b/i.test(codecs)
  const hasAac = PREFER_AUDIO_RE.test(codecs)
  const needsMp2 = /\bmp2a?|mpeg2|mpeg-2\b/i.test(codecs)
  const mp2Unsupported =
    needsMp2 &&
    typeof MediaSource !== "undefined" &&
    !MediaSource.isTypeSupported("audio/mpeg")
  if (needsEc3 && !hasAac && !mseAudioCodecSupported("ec-3")) {
    dispatchUnsupportedAudioCodec(codecs)
  } else if (needsAc3 && !hasAac && !mseAudioCodecSupported("ac-3")) {
    dispatchUnsupportedAudioCodec(codecs)
  } else if (mp2Unsupported) {
    dispatchUnsupportedAudioCodec(codecs)
  }
}

export function dispatchHlsNoAudioDetected(detail: {
  reason?: string
  codecs?: string
}): void {
  try {
    window.dispatchEvent(new CustomEvent("xt:hls-no-audio-detected", { detail }))
  } catch {}
}

function dispatchUnsupportedAudioCodec(codecs: string): void {
  try {
    window.dispatchEvent(
      new CustomEvent("xt:unsupported-audio-codec", { detail: { codecs } }),
    )
  } catch {}
}

/** @deprecated Use wireHlsForArtplayer from embedded-hls-tracks.js */
export function wireHlsAudio(hls: any, video: HTMLVideoElement): void {
  const Hls = hls?.constructor
  if (!Hls?.Events) return

  const selectTrack = () => {
    const idx = pickBestAudioTrackIndex(hls)
    enforceMuxedHlsAudio(hls)
    if (hls.audioTrack !== idx) {
      hls.audioTrack = idx
      log.log("[xt:player] HLS audio track", idx === -1 ? "muxed" : idx)
    }
    const blocked = detectNoPlayableHlsAudio(hls)
    if (blocked.blocked) {
      notifyIfAudioCodecUnsupported(blocked.codecs || "")
      dispatchHlsNoAudioDetected(blocked)
    }
  }

  ensureVideoAudible(video)

  hls.on(Hls.Events.MANIFEST_PARSED, (_event: string, data: unknown) => {
    ensureVideoAudible(video)
    selectTrack()
    notifyIfAudioCodecUnsupported(
      codecsFromHlsManifest(data as { levels?: Array<{ codecs?: string; audioCodec?: string }> }),
    )
  })

  hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, selectTrack)

  hls.on(Hls.Events.LEVEL_SWITCHED, () => {
    ensureVideoAudible(video)
    enforceMuxedHlsAudio(hls)
  })

  video.addEventListener("playing", () => ensureVideoAudible(video))
}
