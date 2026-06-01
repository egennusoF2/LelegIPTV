import { describe, it, expect } from "vitest"
import {
  rewriteM3u8Playlist,
  wrapUrlForStreamProxy,
} from "../src/scripts/lib/m3u8-proxy-rewrite"

describe("wrapUrlForStreamProxy", () => {
  it("wraps remote https URLs", () => {
    const out = wrapUrlForStreamProxy("https://cdn.example.com/live/seg.ts")
    expect(out).toContain("/__stream?url=")
    expect(out).toContain(encodeURIComponent("https://cdn.example.com/live/seg.ts"))
  })

  it("preserves http on port 8080 in the proxied target", () => {
    const src = "http://cdn.example.com:8080/hls/seg.ts"
    const out = wrapUrlForStreamProxy(src)
    expect(out).toContain(encodeURIComponent("http://cdn.example.com:8080/hls/seg.ts"))
    expect(out).not.toContain(encodeURIComponent("https://cdn.example.com:8080"))
  })
})

describe("rewriteM3u8Playlist", () => {
  it("rewrites segment and URI lines", () => {
    const base = "https://panel.example.com/live/user/pass/289.m3u8"
    const input = [
      "#EXTM3U",
      '#EXT-X-MEDIA:TYPE=AUDIO,URI="https://cdn.example.com/audio.m3u8"',
      "https://cdn.example.com/seg001.ts",
    ].join("\n")
    const out = rewriteM3u8Playlist(input, base)
    expect(out).toContain("/__stream?url=")
    expect(out).not.toMatch(/^https:\/\/cdn\.example\.com\/seg001\.ts$/m)
  })
})
