import { describe, it, expect, vi } from "vitest"
import { VttStreamParser, parseVttTimestamp } from "../src/scripts/lib/vtt-stream-parser"

describe("parseVttTimestamp", () => {
  it("parses hh:mm:ss.mmm", () => {
    expect(parseVttTimestamp("01:02:03.500")).toBeCloseTo(3723.5, 3)
  })

  it("parses mm:ss.mmm", () => {
    expect(parseVttTimestamp("02:03.250")).toBeCloseTo(123.25, 3)
  })
})

describe("VttStreamParser", () => {
  it("emits cues as blocks arrive in chunks", () => {
    const cues: string[] = []
    const parser = new VttStreamParser()
    parser.onCue = (cue) => cues.push(cue.text)

    parser.push("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n")
    expect(cues).toEqual([])
    parser.push("First line\n\n00:00:03.000 --> 00:00:04.000\nSecond")
    expect(cues).toEqual(["First line"])
    parser.push("\n\n")
    parser.finish()
    expect(cues).toEqual(["First line", "Second"])
  })

  it("skips NOTE and STYLE blocks without timing", () => {
    const onCue = vi.fn()
    const parser = new VttStreamParser()
    parser.onCue = onCue
    parser.push(
      "WEBVTT\n\nNOTE\nmeta\n\n00:00:10.000 --> 00:00:12.000\nHello\n\n",
    )
    parser.finish()
    expect(onCue).toHaveBeenCalledTimes(1)
    expect(onCue.mock.calls[0][0].text).toBe("Hello")
  })
})
