import { describe, it, expect } from "vitest"
import {
  wrapStreamUrlForDev,
  shouldUseHlsJsForM3u8,
  isTauriEmbedded,
  preferHttpsStreamUrl,
  shouldUpgradeHttpToHttps,
  isIpStreamHost,
  httpFallbackStreamUrl,
  isIptvMediaUrl,
  unwrapStreamProxyUrl,
  STREAM_PROXY_PATH,
} from "../src/scripts/lib/stream-proxy"

describe("preferHttpsStreamUrl", () => {
  it("upgrades http to https on port 80", () => {
    expect(preferHttpsStreamUrl("http://example.com/live/a.m3u8")).toBe(
      "https://example.com/live/a.m3u8",
    )
  })

  it("keeps http on non-standard ports (IPTV CDN shards)", () => {
    const url = "http://1_397.forever-youngs.top:8080/hls/abc/seg.ts"
    expect(preferHttpsStreamUrl(url)).toBe(url)
    expect(shouldUpgradeHttpToHttps(url)).toBe(false)
  })

  it("leaves https unchanged", () => {
    const url = "https://example.com/live/a.m3u8"
    expect(preferHttpsStreamUrl(url)).toBe(url)
  })

  it("downgrades https on raw IP CDNs to http", () => {
    const url = "https://103.240.151.219/hls/abc/212823_359.ts"
    expect(preferHttpsStreamUrl(url)).toBe(
      "http://103.240.151.219/hls/abc/212823_359.ts",
    )
    expect(isIpStreamHost("103.240.151.219")).toBe(true)
    expect(httpFallbackStreamUrl(url)).toBe(
      "http://103.240.151.219/hls/abc/212823_359.ts",
    )
  })
})

describe("wrapStreamUrlForDev", () => {
  it("upgrades http to https outside dev browser (no proxy path)", () => {
    expect(wrapStreamUrlForDev("http://example.com/live/u/p/1.m3u8")).toBe(
      "https://example.com/live/u/p/1.m3u8",
    )
  })
})

describe("unwrapStreamProxyUrl", () => {
  it("unwraps nested proxy URLs", () => {
    const inner = "https://cdn.example.com/live/seg.ts"
    const once = `${STREAM_PROXY_PATH}?url=${encodeURIComponent(inner)}`
    const twice = `${STREAM_PROXY_PATH}?url=${encodeURIComponent(`http://127.0.0.1:4321${once}`)}`
    expect(unwrapStreamProxyUrl(twice)).toBe(inner)
  })

  it("leaves plain CDN URLs unchanged", () => {
    const url = "https://cdn.example.com/live/a.m3u8"
    expect(unwrapStreamProxyUrl(url)).toBe(url)
  })
})

describe("isIptvMediaUrl", () => {
  it("matches live HLS paths", () => {
    expect(
      isIptvMediaUrl("http://panel.example.com/live/user/pass/289.m3u8"),
    ).toBe(true)
  })

  it("does not match player_api", () => {
    expect(
      isIptvMediaUrl(
        "http://panel.example.com/player_api.php?action=get_short_epg",
      ),
    ).toBe(false)
  })

  it("does not match xmltv", () => {
    expect(isIptvMediaUrl("http://panel.example.com/xmltv.php?u=1")).toBe(false)
  })
})

describe("shouldUseHlsJsForM3u8", () => {
  it("returns a boolean", () => {
    expect(typeof shouldUseHlsJsForM3u8()).toBe("boolean")
  })

  it("is true when Tauri embedded (vitest has no window.__TAURI__)", () => {
    expect(isTauriEmbedded()).toBe(false)
    expect(shouldUseHlsJsForM3u8()).toBe(true)
  })
})
