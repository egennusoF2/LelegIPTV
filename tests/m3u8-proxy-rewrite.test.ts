import { describe, expect, it } from "vitest"
import { bodyLooksLikeM3u8, looksLikeM3u8 } from "../src/scripts/lib/m3u8-proxy-rewrite"

describe("m3u8-proxy-rewrite", () => {
  it("detects manifest bodies", () => {
    expect(bodyLooksLikeM3u8("#EXTM3U\n#EXT-X-VERSION:3\n")).toBe(true)
    expect(bodyLooksLikeM3u8("<html><body>error</body></html>")).toBe(false)
  })

  it("rejects HTML error pages even when the URL ends with .m3u8", () => {
    const html = "<!DOCTYPE html><html><body>offline</body></html>"
    expect(
      looksLikeM3u8("text/html; charset=UTF-8", "http://panel.example.com/movie/u/p/1.m3u8", html),
    ).toBe(false)
  })

  it("accepts real manifests", () => {
    const manifest = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nstream.m3u8\n"
    expect(
      looksLikeM3u8("application/vnd.apple.mpegurl", "http://panel.example.com/a.m3u8", manifest),
    ).toBe(true)
  })
})
