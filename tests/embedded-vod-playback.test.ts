import { describe, it, expect } from "vitest"
import {
  toHlsSiblingUrl,
  isXtreamVodContainerUrl,
} from "../src/scripts/lib/embedded-vod-playback"

describe("toHlsSiblingUrl", () => {
  it("rewrites mkv to m3u8", () => {
    expect(
      toHlsSiblingUrl("http://panel.example.com/movie/u/p/123.mkv"),
    ).toBe("http://panel.example.com/movie/u/p/123.m3u8")
  })

  it("rewrites mp4 to m3u8", () => {
    expect(
      toHlsSiblingUrl("http://panel.example.com/series/u/p/9.mp4"),
    ).toBe("http://panel.example.com/series/u/p/9.m3u8")
  })

  it("returns null when already m3u8", () => {
    expect(
      toHlsSiblingUrl("http://panel.example.com/movie/u/p/1.m3u8"),
    ).toBeNull()
  })
})

describe("isXtreamVodContainerUrl", () => {
  it("matches movie mkv paths", () => {
    expect(
      isXtreamVodContainerUrl("http://panel.example.com/movie/u/p/123.mkv"),
    ).toBe(true)
  })

  it("matches series mp4 paths", () => {
    expect(
      isXtreamVodContainerUrl("http://panel.example.com/series/u/p/9.mp4"),
    ).toBe(true)
  })

  it("rejects live streams", () => {
    expect(
      isXtreamVodContainerUrl("http://panel.example.com/live/u/p/1.m3u8"),
    ).toBe(false)
  })
})

describe("preferVodHlsUrl iOS fallback", () => {
  it("documents mkv→m3u8 sibling for Xtream movie paths", () => {
    const mkv = "http://panel.example.com/movie/u/p/123.mkv"
    expect(toHlsSiblingUrl(mkv)).toBe("http://panel.example.com/movie/u/p/123.m3u8")
    expect(isXtreamVodContainerUrl(mkv)).toBe(true)
  })
})
