/**
 * ArtPlayer setting panels: selector leaf clicks invoke the parent `onSelect(item)`,
 * not per-entry `onSelect` on selector items. Helpers + dev diagnostics.
 */
import { log } from "@/scripts/lib/log.js"

const SWAP_IGNORE_MS = 6_000

export function shouldIgnoreContainerVideoError(art: any): boolean {
  return Boolean(art?._xtContainerPlaybackGuard)
}

/** Audio remux or subtitle track updates — ignore transient video errors. */
export function markContainerPlaybackGuard(art: any, ms = SWAP_IGNORE_MS): void {
  if (!art) return
  art._xtContainerPlaybackGuard = true
  if (art._xtContainerAudioSwapTimer) {
    clearTimeout(art._xtContainerAudioSwapTimer)
  }
  art._xtContainerAudioSwapTimer = setTimeout(() => {
    art._xtContainerPlaybackGuard = false
    art._xtContainerAudioSwapTimer = null
  }, ms)
}

export function clearContainerPlaybackGuard(art: any): void {
  if (!art) return
  art._xtContainerPlaybackGuard = false
  if (art._xtContainerAudioSwapTimer) {
    clearTimeout(art._xtContainerAudioSwapTimer)
    art._xtContainerAudioSwapTimer = null
  }
}

/** @deprecated use markContainerPlaybackGuard */
export function markContainerSourceSwap(art: any, ms = SWAP_IGNORE_MS): void {
  markContainerPlaybackGuard(art, ms)
}

/** @deprecated use clearContainerPlaybackGuard */
export function clearContainerSourceSwap(art: any): void {
  clearContainerPlaybackGuard(art)
}

export function trackSettingsDebug(
  stage: string,
  detail: Record<string, unknown> = {},
): void {
  const payload = { stage, ...detail, at: Date.now() }
  log.log("[xt:track-settings]", payload)
  if (!import.meta.env.DEV || typeof document === "undefined") return
  try {
    document.dispatchEvent(
      new CustomEvent("xt:track-settings", { detail: payload }),
    )
  } catch {}
}

/** Metadata attached to selector rows (ArtPlayer passes the row as `item`). */
export type ArtplayerSelectorRow = {
  html: string
  default?: boolean
  _xtKind?: string
  _xtPayload?: unknown
}
