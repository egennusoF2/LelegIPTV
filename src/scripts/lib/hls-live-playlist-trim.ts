/**
 * Trim Xtream media playlists to the live edge (Megacubo HLSJournal idea).
 * Old segments often return HTTP 200 with an empty body — hls.js then stalls forever.
 */

/** Xtream panels often ship 4–6 segments; keep the last two (newest may still be empty). */
const DEFAULT_KEEP_SEGMENTS = 2

interface SegmentPair {
  extinf: string[]
  url: string
}

/** Keep only the newest N EXTINF segments; bump EXT-X-MEDIA-SEQUENCE accordingly. */
export function trimLiveMediaPlaylist(
  body: string,
  keep = DEFAULT_KEEP_SEGMENTS,
): string {
  if (!body.includes("#EXTM3U") || !body.includes("#EXTINF")) return body
  if (body.includes("#EXT-X-STREAM-INF")) return body
  if (body.includes("#EXT-X-ENDLIST")) return body

  const lines = body.split(/\r?\n/)
  const header: string[] = []
  const segments: SegmentPair[] = []
  let i = 0

  while (i < lines.length) {
    const line = lines[i]
    if (line.startsWith("#EXTINF")) {
      const extinf = [line]
      i += 1
      while (i < lines.length && lines[i].startsWith("#") && !lines[i].startsWith("#EXTINF")) {
        extinf.push(lines[i])
        i += 1
      }
      const url =
        i < lines.length && lines[i].trim() && !lines[i].startsWith("#") ? lines[i] : ""
      if (url) {
        segments.push({ extinf, url })
        i += 1
      } else {
        segments.push({ extinf, url: "" })
      }
    } else if (segments.length === 0) {
      header.push(line)
      i += 1
    } else {
      i += 1
    }
  }

  if (segments.length < 2) return body
  if (segments.length <= keep) {
    const drop = segments.length - 1
    if (drop <= 0) return body
    const kept = segments.slice(-1)
    const seqMatch = body.match(/#EXT-X-MEDIA-SEQUENCE:\s*(\d+)/i)
    const baseSeq = seqMatch ? parseInt(seqMatch[1], 10) : 0
    const newSeq = Number.isFinite(baseSeq) ? baseSeq + drop : drop
    const out: string[] = []
    let bumped = false
    for (const line of header) {
      if (/^#EXT-X-MEDIA-SEQUENCE:/i.test(line)) {
        out.push(`#EXT-X-MEDIA-SEQUENCE:${newSeq}`)
        bumped = true
      } else {
        out.push(line)
      }
    }
    if (!bumped) out.push(`#EXT-X-MEDIA-SEQUENCE:${newSeq}`)
    for (const seg of kept) {
      out.push(...seg.extinf, seg.url)
    }
    return `${out.join("\n")}\n`
  }

  const drop = segments.length - keep
  const kept = segments.slice(-keep)
  const seqMatch = body.match(/#EXT-X-MEDIA-SEQUENCE:\s*(\d+)/i)
  const baseSeq = seqMatch ? parseInt(seqMatch[1], 10) : 0
  const newSeq = Number.isFinite(baseSeq) ? baseSeq + drop : drop

  const out: string[] = []
  let bumped = false
  for (const line of header) {
    if (/^#EXT-X-MEDIA-SEQUENCE:/i.test(line)) {
      out.push(`#EXT-X-MEDIA-SEQUENCE:${newSeq}`)
      bumped = true
    } else {
      out.push(line)
    }
  }
  if (!bumped) out.push(`#EXT-X-MEDIA-SEQUENCE:${newSeq}`)

  for (const seg of kept) {
    out.push(...seg.extinf, seg.url)
  }
  return `${out.join("\n")}\n`
}
