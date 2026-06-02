/**
 * ArtPlayer setting panels: selector leaf clicks invoke the parent `onSelect(item)`,
 * not per-entry `onSelect` on selector items. Helpers + dev diagnostics.
 */
import { log } from "@/scripts/lib/log.js"

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
