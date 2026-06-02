/**
 * Pick extractable embedded subtitle tracks for the VOD menu (one best track per language).
 */

export interface ProbeSubtitleStream {
  index?: number
  codec_type?: string
  codec_name?: string
  tags?: { language?: string; title?: string }
}

export interface VodSubtitleTrackMeta {
  /** Index among subtitle streams in file (ffmpeg `0:s:N`). */
  index: number
  language: string
  label: string
  codec: string
  src: string
}

const MAX_SUBTITLE_TRACKS = 32

const EXTRACTABLE_RE =
  /^(subrip|srt|ass|ssa|mov_text|text|webvtt|microdvd|subviewer|mpl2|vplayer|sami|realtext|dvb_teletext)/i

export function isExtractableTextSubtitle(codec: string | undefined): boolean {
  const name = (codec || "").toLowerCase()
  if (!name) return false
  if (
    name.includes("hdmv") ||
    name.includes("pgssub") ||
    name.includes("pgs") ||
    name === "dvd_subtitle" ||
    name.includes("dvb_sub") ||
    name.includes("xsub") ||
    name.includes("bitmap")
  ) {
    return false
  }
  return EXTRACTABLE_RE.test(name) || name.includes("subrip") || name.includes("ass")
}

function subtitleCodecScore(codec: string): number {
  const name = codec.toLowerCase()
  if (name.includes("subrip") || name === "srt") return 100
  if (name.includes("webvtt") || name.includes("mov_text")) return 92
  if (name.includes("ass") || name.includes("ssa")) return 78
  if (name.includes("microdvd") || name.includes("subviewer")) return 60
  return 50
}

function normTag(value: string | undefined): string {
  return String(value || "")
    .trim()
    .toLowerCase()
}

function dedupeKey(language: string, title: string): string {
  const lang = normTag(language) || "und"
  const name = normTag(title)
  if (name && name !== lang && !["und", "unknown"].includes(name)) {
    return `${lang}\0${name}`
  }
  return lang
}

function displayLabel(language: string, title: string, codec: string): string {
  const lang = language.trim()
  const name = title.trim()
  if (name && name.toLowerCase() !== lang.toLowerCase()) {
    return name
  }
  return lang || codec || "Subtitle"
}

/**
 * One menu row per language (best text codec). `subtitleStreamIndex` is ffmpeg `0:s:N`.
 */
export function listExtractableSubtitleTracks(
  streams: ProbeSubtitleStream[],
  buildSrc: (subtitleStreamIndex: number) => string,
  maxTracks = MAX_SUBTITLE_TRACKS,
): VodSubtitleTrackMeta[] {
  const subtitleStreams = streams.filter((s) => s.codec_type === "subtitle")
  const bestByKey = new Map<
    string,
    VodSubtitleTrackMeta & { score: number }
  >()

  for (let i = 0; i < subtitleStreams.length; i++) {
    const stream = subtitleStreams[i]
    const codec = stream.codec_name || ""
    if (!isExtractableTextSubtitle(codec)) continue

    const language = stream.tags?.language || ""
    const title = stream.tags?.title || ""
    const key = dedupeKey(language, title)
    const score = subtitleCodecScore(codec)
    const candidate: VodSubtitleTrackMeta & { score: number } = {
      index: i,
      language,
      label: displayLabel(language, title, codec),
      codec,
      src: buildSrc(i),
      score,
    }

    const prev = bestByKey.get(key)
    if (!prev || score > prev.score) {
      bestByKey.set(key, candidate)
    }
  }

  return Array.from(bestByKey.values())
    .sort((a, b) => a.index - b.index)
    .slice(0, maxTracks)
    .map(({ score: _score, ...track }) => track)
}
