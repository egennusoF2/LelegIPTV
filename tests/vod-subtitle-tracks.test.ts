import { describe, expect, it } from "vitest"
import {
  isExtractableTextSubtitle,
  listExtractableSubtitleTracks,
} from "@/scripts/lib/vod-subtitle-tracks"

describe("vod-subtitle-tracks", () => {
  it("rejects bitmap subtitles", () => {
    expect(isExtractableTextSubtitle("hdmv_pgs_subtitle")).toBe(false)
    expect(isExtractableTextSubtitle("dvd_subtitle")).toBe(false)
  })

  it("accepts common text codecs", () => {
    expect(isExtractableTextSubtitle("subrip")).toBe(true)
    expect(isExtractableTextSubtitle("ass")).toBe(true)
  })

  it("keeps one track per language preferring subrip over ass", () => {
    const tracks = listExtractableSubtitleTracks(
      [
        { codec_type: "subtitle", codec_name: "ass", tags: { language: "ita", title: "ita" } },
        { codec_type: "subtitle", codec_name: "subrip", tags: { language: "ita", title: "ita" } },
        { codec_type: "subtitle", codec_name: "subrip", tags: { language: "eng", title: "eng" } },
      ],
      (i) => `/sub?index=${i}`,
    )
    expect(tracks).toHaveLength(2)
    expect(tracks.find((t) => t.language === "ita")?.codec).toBe("subrip")
    expect(tracks.find((t) => t.language === "ita")?.index).toBe(1)
    expect(tracks[0]?.src).toBe("/sub?index=1")
  })

  it("keeps forced and full subs as separate entries", () => {
    const tracks = listExtractableSubtitleTracks(
      [
        {
          codec_type: "subtitle",
          codec_name: "subrip",
          tags: { language: "ita", title: "Forced" },
        },
        {
          codec_type: "subtitle",
          codec_name: "subrip",
          tags: { language: "ita", title: "Full" },
        },
      ],
      (i) => `/sub?index=${i}`,
    )
    expect(tracks).toHaveLength(2)
    expect(tracks.map((t) => t.label).sort()).toEqual(["Forced", "Full"])
  })
})
