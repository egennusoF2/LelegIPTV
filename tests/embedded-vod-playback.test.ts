import { describe, it, expect } from "vitest"
import {
  toHlsSiblingUrl,
  toMp4SiblingUrl,
  toMkvSiblingUrl,
  isXtreamVodContainerUrl,
  looksLikeOfflineFallback,
  looksLikeVodPlaceholderSnippet,
  parseContentTotalBytes,
  vodContainerTooSmall,
  isLikelyVodPlaceholderDuration,
  parseMp4DurationSec,
  shouldSkipVodHlsSibling,
  shouldSkipVodHlsProbe,
  shouldPreserveVodPlaySrc,
  vodAssetIdFromUrl,
  vodProbeMatchesRequestedAsset,
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

describe("vodProbeMatchesRequestedAsset", () => {
  it("rejects redirects that drop the requested asset id", () => {
    const req = "http://panel.example.com/movie/u/p/633617.mp4"
    expect(
      vodProbeMatchesRequestedAsset(req, "http://cdn.example.com/TS_OFFLINE.mp4", "ftyp"),
    ).toBe(false)
    expect(
      vodProbeMatchesRequestedAsset(req, "http://cdn.example.com/movie/u/p/633617.mp4", "ftyp"),
    ).toBe(true)
  })

  it("extracts vod asset ids from xtream paths", () => {
    expect(vodAssetIdFromUrl("http://panel.example.com/movie/u/p/633617.mkv")).toBe(
      "633617",
    )
    expect(vodAssetIdFromUrl("http://panel.example.com/series/u/p/99123.mp4")).toBe(
      "99123",
    )
  })
})

describe("shouldPreserveVodPlaySrc", () => {
  it("keeps mp4 when backup resolve returns mkv for same vod id", () => {
    const mp4 = "http://panel.example.com/movie/u/p/633617.mp4"
    const mkv = "http://backup.example.com/movie/u/p/633617.mkv"
    expect(shouldPreserveVodPlaySrc(mp4, mkv)).toBe(true)
    expect(shouldPreserveVodPlaySrc(mkv, mp4)).toBe(false)
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

describe("vod placeholder detection", () => {
  it("detects Spanish standby text in MP4 moov", () => {
    expect(looksLikeVodPlaceholderSnippet("EN UNOS MOMENTOS ESTAREMOS")).toBe(true)
  })

  it("parses total bytes from Content-Range", () => {
    const res = new Response(null, {
      status: 206,
      headers: { "content-range": "bytes 0-2047/3456789" },
    })
    expect(parseContentTotalBytes(res)).toBe(3456789)
  })

  it("ignores partial Content-Length on 206", () => {
    const res = new Response(null, {
      status: 206,
      headers: { "content-length": "2048" },
    })
    expect(parseContentTotalBytes(res)).toBeNull()
  })

  it("rejects movie files smaller than 5MB", () => {
    const url = "http://panel.example.com/movie/u/p/8479.mp4"
    expect(vodContainerTooSmall(url, 2 * 1024 * 1024)).toBe(true)
    expect(vodContainerTooSmall(url, 8 * 1024 * 1024)).toBe(false)
  })

  it("flags ~35s clips as placeholders for movies", () => {
    const url = "http://panel.example.com/movie/u/p/8479.mp4"
    expect(isLikelyVodPlaceholderDuration(url, 35)).toBe(true)
    expect(isLikelyVodPlaceholderDuration(url, 3600)).toBe(false)
  })

  it("rejects placeholder text in probe asset match", () => {
    const req = "http://panel.example.com/movie/u/p/8479.mp4"
    expect(
      vodProbeMatchesRequestedAsset(req, req, "ftypMOMENTOS ESTAREMOS"),
    ).toBe(false)
  })

  it("reads short mvhd duration from MP4 header bytes", () => {
    const mvhdPayload = 84
    const mvhdSize = 8 + mvhdPayload
    const moovSize = 8 + mvhdSize
    const buf = new ArrayBuffer(moovSize)
    const bytes = new Uint8Array(buf)
    const view = new DataView(buf)
    view.setUint32(0, moovSize)
    bytes[4] = "m".charCodeAt(0)
    bytes[5] = "o".charCodeAt(0)
    bytes[6] = "o".charCodeAt(0)
    bytes[7] = "v".charCodeAt(0)
    view.setUint32(8, mvhdSize)
    bytes[12] = "m".charCodeAt(0)
    bytes[13] = "v".charCodeAt(0)
    bytes[14] = "h".charCodeAt(0)
    bytes[15] = "d".charCodeAt(0)
    view.setUint32(16 + 12, 1000)
    view.setUint32(16 + 16, 35_000)
    expect(parseMp4DurationSec(buf)).toBeCloseTo(35, 1)
    const url = "http://panel.example.com/series/u/p/256852.mp4"
    expect(isLikelyVodPlaceholderDuration(url, parseMp4DurationSec(buf)!)).toBe(true)
  })
})
