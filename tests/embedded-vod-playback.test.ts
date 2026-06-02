import { describe, it, expect } from "vitest"
import {
  toHlsSiblingUrl,
  toMp4SiblingUrl,
  toMkvSiblingUrl,
  isXtreamVodContainerUrl,
  looksLikeOfflineFallback,
  shouldSkipVodHlsSibling,
  shouldSkipVodHlsProbe,
  isXtreamSeriesContainerUrl,
  containerExtensionFromUrl,
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

describe("toMkvSiblingUrl", () => {
  it("rewrites series mp4 to mkv", () => {
    expect(
      toMkvSiblingUrl("http://panel.example.com/series/u/p/347677.mp4"),
    ).toBe("http://panel.example.com/series/u/p/347677.mkv")
  })
})

describe("toMp4SiblingUrl", () => {
  it("rewrites mkv to mp4", () => {
    expect(
      toMp4SiblingUrl("http://panel.example.com/movie/u/p/123.mkv"),
    ).toBe("http://panel.example.com/movie/u/p/123.mp4")
  })

  it("returns null when already mp4", () => {
    expect(
      toMp4SiblingUrl("http://panel.example.com/movie/u/p/123.mp4"),
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

describe("shouldSkipVodHlsSibling", () => {
  it("skips HLS probe for mkv-only panels", () => {
    const mkv = "http://panel.example.com/movie/u/p/734099.mkv"
    expect(containerExtensionFromUrl(mkv)).toBe("mkv")
    expect(shouldSkipVodHlsSibling(mkv)).toBe(true)
    expect(shouldSkipVodHlsSibling(mkv, "mkv")).toBe(true)
  })

  it("still allows HLS probe for mp4 movie containers", () => {
    expect(shouldSkipVodHlsSibling("http://panel.example.com/movie/u/p/1.mp4")).toBe(false)
  })
})

describe("shouldSkipVodHlsProbe", () => {
  it("skips HLS for series episode mp4", () => {
    const ep = "http://panel.example.com/series/u/p/347677.mp4"
    expect(isXtreamSeriesContainerUrl(ep)).toBe(true)
    expect(shouldSkipVodHlsProbe(ep)).toBe(true)
    expect(shouldSkipVodHlsProbe(ep, "mp4")).toBe(true)
  })

  it("still probes HLS for mp4 movies when panel may serve m3u8", () => {
    const movie = "http://panel.example.com/movie/u/p/1.mp4"
    expect(shouldSkipVodHlsProbe(movie)).toBe(false)
  })
})

describe("preferVodHlsUrl iOS fallback", () => {
  it("documents mkv→m3u8 sibling for Xtream movie paths", () => {
    const mkv = "http://panel.example.com/movie/u/p/123.mkv"
    expect(toHlsSiblingUrl(mkv)).toBe("http://panel.example.com/movie/u/p/123.m3u8")
    expect(isXtreamVodContainerUrl(mkv)).toBe(true)
  })
})

describe("looksLikeOfflineFallback", () => {
  it("detects provider placeholder MP4 fallbacks", () => {
    expect(looksLikeOfflineFallback("http://cdn.example.com/TS_OFFLINE.mp4")).toBe(true)
    expect(looksLikeOfflineFallback("video placeholder content")).toBe(true)
  })

  it("does not flag normal stream urls", () => {
    expect(looksLikeOfflineFallback("http://cdn.example.com/movie/u/p/202400.mkv")).toBe(false)
  })
})
