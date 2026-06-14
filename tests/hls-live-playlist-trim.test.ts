import { describe, expect, it } from "vitest"
import { trimLiveMediaPlaylist } from "@/scripts/lib/hls-live-playlist-trim"

describe("trimLiveMediaPlaylist", () => {
  it("keeps only the newest segment when the panel ships a short stale window", () => {
    const input = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:4",
      "#EXT-X-MEDIA-SEQUENCE:1481",
      "#EXTINF:4.0,",
      "http://cdn/288692_1481.ts",
      "#EXTINF:4.0,",
      "http://cdn/288692_1482.ts",
      "#EXTINF:4.0,",
      "http://cdn/288692_1483.ts",
      "#EXTINF:4.0,",
      "http://cdn/288692_1484.ts",
      "#EXTINF:4.0,",
      "http://cdn/288692_1485.ts",
    ].join("\n")

    const out = trimLiveMediaPlaylist(input)
    expect(out).not.toContain("288692_1481.ts")
    expect(out).not.toContain("288692_1482.ts")
    expect(out).toContain("288692_1484.ts")
    expect(out).toContain("288692_1485.ts")
    expect(out).toMatch(/#EXT-X-MEDIA-SEQUENCE:1484/)
  })

  it("does not trim VOD playlists with ENDLIST", () => {
    const input = "#EXTM3U\n#EXT-X-ENDLIST\n#EXTINF:10,\nseg.ts\n"
    expect(trimLiveMediaPlaylist(input)).toBe(input)
  })
})
