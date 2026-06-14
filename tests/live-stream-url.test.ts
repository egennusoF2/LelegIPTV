import { describe, expect, it } from "vitest"
import {
  isUpstreamLiveHls,
  isUpstreamLiveTs,
  upstreamLiveStreamKind,
} from "@/scripts/lib/live-stream-url"

describe("upstreamLiveStreamKind", () => {
  it("detects HLS inside native proxy URLs", () => {
    const proxied =
      "http://127.0.0.1:54715/__stream?url=http%3A%2F%2Fpanel.example.com%2Flive%2Fu%2Fp%2F462973.m3u8&ua=iptv"
    expect(upstreamLiveStreamKind(proxied)).toBe("hls")
    expect(isUpstreamLiveHls(proxied)).toBe(true)
    expect(isUpstreamLiveTs(proxied)).toBe(false)
  })

  it("detects MPEG-TS direct URLs", () => {
    expect(isUpstreamLiveTs("http://panel.example.com/live/u/p/99.ts")).toBe(true)
  })
})
