import { describe, expect, it } from "vitest"
import {
  formatContainerAudioLabel,
  formatContainerSubtitleLabel,
  humanizeAudioCodec,
} from "@/scripts/lib/media-track-labels"

describe("media-track-labels", () => {
  it("replaces und with readable audio label", () => {
    const label = formatContainerAudioLabel(
      { index: 0, language: "und", label: "und", codec: "aac" },
      0,
    )
    expect(label).toBe("Audio 1 · AAC")
    expect(label).not.toContain("und")
  })

  it("shows language name when present", () => {
    const label = formatContainerAudioLabel(
      { index: 1, language: "ita", label: "", codec: "aac" },
      1,
    )
    expect(label.toLowerCase()).toMatch(/ital/)
    expect(label).toContain("AAC")
  })

  it("falls back to Audio N when metadata empty", () => {
    expect(formatContainerAudioLabel({ index: 2 }, 2)).toBe("Audio 3")
  })

  it("formats subtitle without duplicate und", () => {
    const label = formatContainerSubtitleLabel(
      { index: 0, language: "eng", label: "English" },
      0,
    )
    expect(label.toLowerCase()).toMatch(/english|inglese/)
  })

  it("humanizes codecs", () => {
    expect(humanizeAudioCodec("eac3")).toBe("Dolby Digital")
    expect(humanizeAudioCodec("aac")).toBe("AAC")
  })
})
