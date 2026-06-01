import { describe, it, expect } from "vitest"
import {
  preferredLiveContainer,
  liveStreamExtension,
  allowAutoTsFallback,
} from "../src/scripts/lib/live-container"

describe("preferredLiveContainer", () => {
  it("returns ts when playlist is configured for MPEG-TS", () => {
    expect(preferredLiveContainer({ liveContainer: "ts" })).toBe("ts")
    expect(preferredLiveContainer({ liveContainer: "mpegts" })).toBe("ts")
  })

  it("returns hls when playlist is configured for m3u8", () => {
    expect(preferredLiveContainer({ liveContainer: "m3u8" })).toBe("hls")
    expect(preferredLiveContainer({ liveContainer: "hls" })).toBe("hls")
  })

  it("defaults to hls when unset (Chrome/desktop embedded path)", () => {
    expect(preferredLiveContainer({})).toBe("hls")
    expect(preferredLiveContainer(null)).toBe("hls")
  })
})

describe("liveStreamExtension", () => {
  it("maps container to Xtream file extension", () => {
    expect(liveStreamExtension("hls")).toBe(".m3u8")
    expect(liveStreamExtension("ts")).toBe(".ts")
  })
})

describe("allowAutoTsFallback", () => {
  it("allows TS fallback when playlist prefers TS", () => {
    expect(allowAutoTsFallback({ liveContainer: "ts" })).toBe(true)
  })

  it("allows TS fallback when MSE supports E-AC-3", () => {
    const supported =
      typeof MediaSource !== "undefined" &&
      MediaSource.isTypeSupported('audio/mp4;codecs="ec-3"')
    expect(allowAutoTsFallback({ liveContainer: "m3u8" })).toBe(supported)
  })
})
