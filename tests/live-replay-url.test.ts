import { describe, expect, it } from "vitest"
import { parseReplayWindowFromSearchParams } from "@/scripts/lib/live-replay-url"

describe("parseReplayWindowFromSearchParams", () => {
  it("returns null when catchup params are absent (not Number(null) === 0)", () => {
    const params = new URLSearchParams("channel=462972")
    expect(parseReplayWindowFromSearchParams(params)).toBeNull()
  })

  it("parses a valid catchup window", () => {
    const params = new URLSearchParams(
      "channel=1&catchupStart=1700000000000&catchupStop=1700003600000",
    )
    expect(parseReplayWindowFromSearchParams(params)).toEqual({
      start: 1700000000000,
      stop: 1700003600000,
    })
  })

  it("rejects zero-length windows", () => {
    const params = new URLSearchParams("catchupStart=0&catchupStop=0")
    expect(parseReplayWindowFromSearchParams(params)).toBeNull()
  })
})
