import { describe, expect, it } from "vitest"
import {
  NativePlaybackSession,
  snapshotMediaTracksFromElement,
  type NativePlaybackStatus,
} from "../src/scripts/lib/playback-session"

describe("snapshotMediaTracksFromElement", () => {
  it("normalizes audio and subtitle tracks", () => {
    const video = {
      audioTracks: [
        { id: "ita", label: "Italiano", language: "it", enabled: true },
        { id: "eng", label: "English", language: "en", enabled: false },
      ],
      textTracks: [
        { id: "meta", kind: "metadata", label: "ID3", language: "", mode: "hidden" },
        { id: "sub-it", kind: "subtitles", label: "Italian", language: "it", mode: "showing" },
        { id: "sub-en", kind: "subtitles", label: "English", language: "en", mode: "disabled" },
      ],
    } as unknown as HTMLVideoElement

    const tracks = snapshotMediaTracksFromElement(video)

    expect(tracks.selectedAudioId).toBe("ita")
    expect(tracks.selectedSubtitleId).toBe("sub-it")
    expect(tracks.audio.map((track) => track.label)).toEqual(["Italiano", "English"])
    expect(tracks.subtitles.map((track) => track.id)).toEqual(["sub-it", "sub-en"])
  })

  it("returns empty tracks without a video element", () => {
    expect(snapshotMediaTracksFromElement(null)).toEqual({
      audio: [],
      subtitles: [],
      selectedAudioId: null,
      selectedSubtitleId: null,
    })
  })
})

describe("NativePlaybackSession", () => {
  it("exposes a Video.js-shaped handle for existing pages", async () => {
    const calls: Array<{ cmd: string; args?: Record<string, unknown> }> = []
    const invoke = async (cmd: string, args?: Record<string, unknown>) => {
      calls.push({ cmd, args })
      if (cmd === "native_playback_state") {
        return {
          backend: "macos-libmpv",
          available: true,
          loaded: true,
          paused: false,
          ended: false,
          currentTime: 12,
          duration: 60,
          audio: [],
          subtitles: [],
          selectedAudioId: null,
          selectedSubtitleId: null,
          error: null,
        }
      }
      return null
    }
    const status: NativePlaybackStatus = {
      platform: "macos",
      available: true,
      backend: "macos-libmpv",
      integrated: true,
      reason: "test",
      nextStep: "test",
    }
    const video = {
      getBoundingClientRect: () => ({
        left: 10,
        top: 20,
        width: 640,
        height: 360,
      }),
    } as unknown as HTMLVideoElement
    const session = new NativePlaybackSession(video, invoke, status)

    session.handle.src({ src: "https://example.com/a.mkv", type: "video/x-matroska" })
    await session.handle.play?.()
    session.handle.currentTime?.(30)
    session.handle.pause()

    expect(calls.map((call) => call.cmd)).toEqual([
      "native_playback_attach",
      "native_playback_attach",
      "native_playback_load",
      "native_playback_play",
      "native_playback_state",
      "native_playback_seek",
      "native_playback_pause",
    ])
  })
})
