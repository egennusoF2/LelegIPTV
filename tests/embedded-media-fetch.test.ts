import { describe, it, expect } from "vitest"
import {
  buildHlsStreamRequest,
  buildHlsXhrSetup,
} from "../src/scripts/lib/embedded-media-fetch"

describe("buildHlsStreamRequest", () => {
  it("returns a Request, not a Promise", () => {
    const req = buildHlsStreamRequest("http://cdn.example.com/live/1.m3u8")
    expect(req).toBeInstanceOf(Request)
    expect(req.url).toContain("cdn.example.com")
  })

  it("does not return a thenable (hls.js would mis-handle Promise<Response>)", () => {
    const req = buildHlsStreamRequest("https://cdn.example.com/seg.ts")
    expect(typeof ((req as unknown as Promise<unknown>).then)).not.toBe("function")
  })
})

describe("buildHlsXhrSetup", () => {
  it("opens XHR without throwing", () => {
    let openedUrl = ""
    const xhr = {
      open(_method: string, url: string) {
        openedUrl = url
      },
      setRequestHeader() {},
    } as unknown as XMLHttpRequest
    buildHlsXhrSetup(xhr, "http://cdn.example.com/live/1.m3u8")
    expect(openedUrl).toMatch(/cdn\.example\.com|__stream/)
  })
})
