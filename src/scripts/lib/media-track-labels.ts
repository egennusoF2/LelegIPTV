/**
 * Human-readable labels for audio/subtitle tracks (ffprobe, HLS, native).
 */

const BORING_LANG = new Set([
  "",
  "und",
  "unknown",
  "undefined",
  "qaa",
  "qad",
  "nar",
])

function clean(value: unknown): string {
  return String(value || "").trim()
}

function languageDisplayName(code: string, locale = "it"): string {
  const raw = clean(code).toLowerCase()
  if (!raw || BORING_LANG.has(raw)) return ""
  if (raw.length === 2 || raw.length === 3) {
    try {
      const name = new Intl.DisplayNames([locale, "en"], { type: "language" }).of(
        raw.length === 3 ? raw : raw,
      )
      if (name && name.toLowerCase() !== raw) return name
    } catch {}
    return raw.toUpperCase()
  }
  return raw
}

export function humanizeAudioCodec(codec: string | undefined): string {
  const name = clean(codec).toLowerCase()
  if (!name) return ""
  if (name.includes("eac3") || name === "ac3") return "Dolby Digital"
  if (name.includes("aac")) return "AAC"
  if (name.includes("mp3")) return "MP3"
  if (name.includes("opus")) return "Opus"
  if (name.includes("flac")) return "FLAC"
  if (name.includes("dts")) return "DTS"
  if (name.includes("pcm")) return "PCM"
  return name.toUpperCase()
}

function dedupeParts(parts: string[]): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const part of parts) {
    const key = part.toLowerCase()
    if (!part || seen.has(key)) continue
    seen.add(key)
    out.push(part)
  }
  return out
}

export interface ContainerTrackLabelInput {
  index?: number
  language?: string
  label?: string
  codec?: string
}

/** e.g. "Italiano · AAC" instead of "und · und · aac" */
export function formatContainerAudioLabel(
  track: ContainerTrackLabelInput,
  listPosition: number,
): string {
  const lang = languageDisplayName(track.language || "")
  const title = clean(track.label)
  const titleOk =
    title && !BORING_LANG.has(title.toLowerCase()) && title.toLowerCase() !== lang.toLowerCase()
  const codec = humanizeAudioCodec(track.codec)
  const parts = dedupeParts([lang, titleOk ? title : "", codec])
  const n = typeof track.index === "number" ? track.index + 1 : listPosition + 1
  if (parts.length > 0) {
    if (!lang && !titleOk && codec) return `Audio ${n} · ${codec}`
    return parts.join(" · ")
  }
  return `Audio ${n}`
}

function humanizeSubtitleCodec(codec: string | undefined): string {
  const name = clean(codec).toLowerCase()
  if (!name) return ""
  if (name.includes("subrip") || name === "srt") return "SRT"
  if (name.includes("ass") || name.includes("ssa")) return "ASS"
  if (name.includes("webvtt")) return "VTT"
  if (name.includes("mov_text")) return "Text"
  return name.toUpperCase()
}

export function formatContainerSubtitleLabel(
  track: ContainerTrackLabelInput,
  listPosition: number,
): string {
  const lang = languageDisplayName(track.language || "")
  const title = clean(track.label)
  const titleOk =
    title &&
    !BORING_LANG.has(title.toLowerCase()) &&
    title.toLowerCase() !== lang.toLowerCase() &&
    title.toLowerCase() !== humanizeSubtitleCodec(track.codec).toLowerCase()
  const codec = humanizeSubtitleCodec(track.codec)
  const parts = dedupeParts([lang, titleOk ? title : "", codec])
  if (parts.length > 0) return parts.join(" · ")
  const n = typeof track.index === "number" ? track.index + 1 : listPosition + 1
  return `Subtitle ${n}`
}

/** Native `audioTracks` / HLS manifest fields. */
export function formatMediaTrackLabel(
  fields: {
    label?: string
    language?: string
    lang?: string
    name?: string
    codec?: string
    id?: string
    groupId?: string
  },
  listPosition: number,
  kind: "audio" | "subtitle",
): string {
  const lang = languageDisplayName(fields.language || fields.lang || "")
  const title = clean(fields.label || fields.name || "")
  const titleOk =
    title && !BORING_LANG.has(title.toLowerCase()) && title.toLowerCase() !== lang.toLowerCase()
  const codec = kind === "audio" ? humanizeAudioCodec(fields.codec) : ""
  const group = clean(fields.groupId)
  const groupOk =
    group && !BORING_LANG.has(group.toLowerCase()) && group.toLowerCase() !== lang.toLowerCase()
  const parts =
    kind === "audio"
      ? dedupeParts([lang, titleOk ? title : "", codec, groupOk ? group : ""])
      : dedupeParts([lang, titleOk ? title : ""])
  if (parts.length > 0) return parts.join(" · ")
  const base = kind === "audio" ? "Audio" : "Subtitle"
  return `${base} ${listPosition + 1}`
}
