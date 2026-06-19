import { describe, expect, it } from "vitest"
import {
  IPTV_UA_HLS,
  IPTV_UA_VOD,
  resolveUpstreamUserAgent,
} from "@/scripts/lib/stream-proxy"

describe("resolveUpstreamUserAgent", () => {
  it("uses VLC UA for VOD sibling manifests so panels keep Range/redirect behavior", () => {
    const url =
      "http://panel.example/movie/user/pass/734099.m3u8"
    expect(resolveUpstreamUserAgent(url)).toBe(IPTV_UA_VOD)
  })

  it("uses VLC UA for VOD container files", () => {
    const url =
      "http://panel.example/movie/user/pass/734099.mkv"
    expect(resolveUpstreamUserAgent(url)).toBe(IPTV_UA_VOD)
  })

  it("uses IPTV player UA for live paths", () => {
    const url = "http://panel.example/live/user/pass/100.ts"
    expect(resolveUpstreamUserAgent(url)).toBe(IPTV_UA_HLS)
  })
})
