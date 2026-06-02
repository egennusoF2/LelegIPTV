import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { shouldUseShakaForAdaptive } from "../src/scripts/lib/player-runtime"

describe("shouldUseShakaForAdaptive", () => {
  beforeEach(() => {
    vi.stubGlobal("window", {
      location: { search: "" },
    })
    vi.stubGlobal("localStorage", {
      getItem: vi.fn(() => null),
      setItem: vi.fn(),
      removeItem: vi.fn(),
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("does not enable Shaka for VOD by default", () => {
    expect(shouldUseShakaForAdaptive("hls", false)).toBe(false)
    expect(shouldUseShakaForAdaptive("dash", false)).toBe(false)
  })

  it("never enables Shaka for live", () => {
    expect(shouldUseShakaForAdaptive("hls", true)).toBe(false)
  })

  it("enables Shaka when ?shaka=1", () => {
    vi.stubGlobal("window", {
      location: { search: "?shaka=1" },
    })
    expect(shouldUseShakaForAdaptive("hls", false)).toBe(true)
  })

  it("ignores non-adaptive kinds", () => {
    expect(shouldUseShakaForAdaptive("ts", false)).toBe(false)
    expect(shouldUseShakaForAdaptive("native", false)).toBe(false)
  })
})
