/**
 * Incremental WebVTT parser for ffmpeg stdout streamed over HTTP.
 * Emits cues as soon as each block is complete (blank-line separated).
 */

export interface ParsedVttCue {
  start: number
  end: number
  text: string
}

/** Parse `00:01:02.500` or `01:02.500` (hours optional) to seconds. */
export function parseVttTimestamp(raw: string): number {
  const value = raw.trim()
  const parts = value.split(":")
  if (parts.length < 2 || parts.length > 3) return NaN

  const parseSec = (segment: string) => {
    const [sec, ms = "0"] = segment.split(".")
    return (
      parseInt(sec, 10) * 1 +
      parseInt(ms.padEnd(3, "0").slice(0, 3), 10) / 1000
    )
  }

  if (parts.length === 3) {
    const hours = parseInt(parts[0], 10)
    const minutes = parseInt(parts[1], 10)
    const seconds = parseSec(parts[2])
    if ([hours, minutes, seconds].some((n) => Number.isNaN(n))) return NaN
    return hours * 3600 + minutes * 60 + seconds
  }

  const minutes = parseInt(parts[0], 10)
  const seconds = parseSec(parts[1])
  if ([minutes, seconds].some((n) => Number.isNaN(n))) return NaN
  return minutes * 60 + seconds
}

const CUE_TIMING_RE =
  /^([\d:.]+)\s*-->\s*([\d:.]+)(?:\s+[\w:-]+)*$/i

export class VttStreamParser {
  private buffer = ""
  private headerSeen = false

  onCue?: (cue: ParsedVttCue) => void

  push(chunk: string): void {
    if (!chunk) return
    this.buffer += chunk.replace(/\r\n/g, "\n")
    this.drain(false)
  }

  finish(): void {
    this.buffer += "\n\n"
    this.drain(true)
    this.buffer = ""
  }

  private drain(finish: boolean): void {
    while (true) {
      const sep = this.buffer.indexOf("\n\n")
      if (sep < 0) {
        if (finish && this.buffer.trim()) {
          this.parseBlock(this.buffer)
          this.buffer = ""
        }
        return
      }
      const block = this.buffer.slice(0, sep)
      this.buffer = this.buffer.slice(sep + 2)
      this.parseBlock(block)
    }
  }

  private parseBlock(block: string): void {
    const lines = block.split("\n").map((line) => line.trimEnd())
    while (lines.length && !lines[0].trim()) lines.shift()
    while (lines.length && !lines[lines.length - 1].trim()) lines.pop()
    if (!lines.length) return

    if (!this.headerSeen && lines[0].startsWith("WEBVTT")) {
      this.headerSeen = true
      lines.shift()
      while (lines.length && !lines[0].trim()) lines.shift()
      if (!lines.length) return
    }

    let timingIndex = lines.findIndex((line) => CUE_TIMING_RE.test(line.trim()))
    if (timingIndex < 0) return

    const timingLine = lines[timingIndex].trim().replace(/(\d),(\d)/g, "$1.$2")
    const text = lines
      .slice(timingIndex + 1)
      .join("\n")
      .trim()
    if (!text) return

    const match = CUE_TIMING_RE.exec(timingLine)
    if (!match) return

    const start = parseVttTimestamp(match[1])
    const end = parseVttTimestamp(match[2])
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return

    this.onCue?.({ start, end, text })
  }
}
