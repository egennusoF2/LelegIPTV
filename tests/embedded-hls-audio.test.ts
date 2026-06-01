import { describe, it, expect } from "vitest"
import {
  pickBestAudioTrackIndex,
  codecsFromHlsManifest,
  levelCodecsHaveMuxedAudio,
  detectNoPlayableHlsAudio,
} from "../src/scripts/lib/embedded-hls-audio"

describe("pickBestAudioTrackIndex", () => {
  it("prefers AAC over AC-3 when both are listed", () => {
    const idx = pickBestAudioTrackIndex({
      audioTracks: [
        { name: "Italian AC3", codec: "ac-3" },
        { name: "Italian AAC", codec: "mp4a.40.2" },
      ],
    })
    expect(idx).toBe(1)
  })

  it("returns -1 when there are no alternate tracks", () => {
    expect(pickBestAudioTrackIndex({ audioTracks: [] })).toBe(-1)
  })

  it("returns -1 (muxed default) when alternates are only AC-3", () => {
    expect(
      pickBestAudioTrackIndex({
        audioTracks: [{ name: "Italian AC3", codec: "ac-3" }],
      }),
    ).toBe(-1)
  })

  it("returns -1 for unknown alternate codecs (no blind fallback)", () => {
    expect(
      pickBestAudioTrackIndex({
        audioTracks: [{ name: "Track A", lang: "ita" }],
      }),
    ).toBe(-1)
  })
})

describe("codecsFromHlsManifest", () => {
  it("joins level codec strings", () => {
    expect(
      codecsFromHlsManifest({
        levels: [{ codecs: "avc1.4d401f,mp4a.40.2", audioCodec: "mp4a.40.2" }],
      }),
    ).toContain("mp4a.40.2")
  })
})

describe("levelCodecsHaveMuxedAudio", () => {
  it("detects video-only levels", () => {
    expect(levelCodecsHaveMuxedAudio("avc1.640028")).toBe(false)
    expect(levelCodecsHaveMuxedAudio("avc1.640028,mp4a.40.2")).toBe(true)
  })
})

describe("detectNoPlayableHlsAudio", () => {
  it("flags AC-3-only muxed streams on Chrome-like MSE", () => {
    const result = detectNoPlayableHlsAudio({
      levels: [{ codecs: "avc1.640028,ac-3" }],
      audioTracks: [],
    })
    if (!globalThis.MediaSource) return
    expect(result.blocked).toBe(true)
  })

  it("allows AAC muxed streams", () => {
    const result = detectNoPlayableHlsAudio({
      levels: [{ codecs: "avc1.640028,mp4a.40.2" }],
      audioTracks: [],
    })
    expect(result.blocked).toBe(false)
  })

  it("allows video-only when AAC alternate exists", () => {
    const result = detectNoPlayableHlsAudio({
      levels: [{ codecs: "avc1.640028" }],
      audioTracks: [{ codec: "mp4a.40.2", name: "Italian" }],
    })
    expect(result.blocked).toBe(false)
  })
})
