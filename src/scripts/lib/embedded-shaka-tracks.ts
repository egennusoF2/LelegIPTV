import { log, redactUrl } from "@/scripts/lib/log.js"
import { t } from "@/scripts/lib/i18n.js"
import {
  devProxyFetchHeaders,
  unwrapStreamProxyUrl,
  useDevStreamProxy,
  wrapStreamUrlForDev,
} from "@/scripts/lib/stream-proxy"
import { resolveMediaHeaders } from "@/scripts/lib/embedded-media-fetch.js"
import {
  clearTrackPreference,
  findPreferredTrackIndex,
  saveTrackPreference,
} from "@/scripts/lib/media-track-preferences"

const SETTING_AUDIO = "xt-shaka-audio"
const SETTING_SUBTITLE = "xt-shaka-subtitle"

type ShakaTrack = {
  id?: number
  active?: boolean
  language?: string
  lang?: string
  label?: string
  roles?: string[]
  codecs?: string
  audioCodec?: string
  channelsCount?: number
}

export interface ShakaHandle {
  destroy: () => Promise<void> | void
  player: any
}

function labelForTrack(
  track: ShakaTrack,
  fallback: string,
): string {
  const parts = [
    track.label,
    track.language || track.lang,
    track.roles?.join("/"),
    track.codecs || track.audioCodec,
    track.channelsCount ? `${track.channelsCount}ch` : "",
  ].filter(Boolean)
  return parts.length ? parts.join(" · ") : fallback
}

function shortHint(value: string): string {
  const clean = String(value || "").replace(/\s+/g, " ").trim()
  if (!clean) return ""
  return clean.length > 28 ? `${clean.slice(0, 25)}...` : clean
}

function menuTitle(title: string, hint: string): string {
  const compact = shortHint(hint)
  return compact
    ? `${title} <span class="opacity-70 text-2xs">· ${compact}</span>`
    : title
}

function refreshShakaTrackSettings(art: any, player: any, opts?: { live?: boolean }): void {
  if (!art?.setting || !player) return
  try { art.setting.remove(SETTING_AUDIO) } catch {}
  try { art.setting.remove(SETTING_SUBTITLE) } catch {}

  const audioTracks: ShakaTrack[] =
    typeof player.getAudioTracks === "function"
      ? player.getAudioTracks()
      : (player.getVariantTracks?.() || [])
  const activeAudio =
    audioTracks.find((track) => track.active) || audioTracks[0] || null
  const audioSelector: Array<{ html: string; default?: boolean; onSelect?: () => void }> =
    audioTracks.map((track, index) => ({
      html: labelForTrack(track, `${t("player.track.audio") || "Audio"} ${index + 1}`),
      default: Boolean(track.active),
      onSelect() {
        try {
          if (typeof player.selectAudioTrack === "function") {
            player.selectAudioTrack(track)
          } else {
            player.configure?.({ abr: { enabled: false } })
            player.selectVariantTrack?.(track, true)
          }
          saveTrackPreference("audio", {
            id: track.id == null ? "" : String(track.id),
            language: track.language || track.lang || "",
            label: track.label || "",
            name: track.label || "",
          })
          setTimeout(() => refreshShakaTrackSettings(art, player), 200)
        } catch (error) {
          log.warn("[xt:player] Shaka audio select failed", error)
        }
      },
    }))

  if (audioSelector.length > 0) {
    art.setting.add({
      name: SETTING_AUDIO,
      html: menuTitle(
        t("player.menu.audio") || "Audio",
        activeAudio
          ? labelForTrack(activeAudio, t("player.track.audio") || "Audio")
          : "",
      ),
      width: 300,
      selector: audioSelector,
    })
  }

  const textTracks: ShakaTrack[] = player.getTextTracks?.() || []
  const activeText = textTracks.find((track) => track.active) || null
  const textSelector: Array<{ html: string; default?: boolean; onSelect?: () => void }> = [
    {
      html: t("player.subtitle.off") || "Off",
      default: activeText == null || !player.isTextTrackVisible?.(),
      onSelect() {
        try {
          player.setTextTrackVisibility?.(false)
          // NOTE: do NOT call selectTextTrack(null) — Shaka v5 throws on null
          clearTrackPreference("subtitle")
          setTimeout(() => refreshShakaTrackSettings(art, player), 200)
        } catch (error) {
          log.warn("[xt:player] Shaka subtitle off failed", error)
        }
      },
    },
    ...textTracks.map((track, index) => ({
      html: labelForTrack(track, `${t("player.track.subtitle") || "Subtitle"} ${index + 1}`),
      default: Boolean(track.active),
      onSelect() {
        try {
          player.selectTextTrack?.(track)
          player.setTextTrackVisibility?.(true)
          saveTrackPreference("subtitle", {
            id: track.id == null ? "" : String(track.id),
            language: track.language || track.lang || "",
            label: track.label || "",
            name: track.label || "",
          })
          setTimeout(() => refreshShakaTrackSettings(art, player), 200)
        } catch (error) {
          log.warn("[xt:player] Shaka subtitle select failed", error)
        }
      },
    })),
  ]

  // Show subtitle menu always (with just "Off") on live, or when tracks exist on VOD
  if (textTracks.length > 0 || opts?.live) {
    art.setting.add({
      name: SETTING_SUBTITLE,
      html: menuTitle(
        t("player.menu.subtitle") || "Subtitles",
        activeText && player.isTextTrackVisible?.()
          ? labelForTrack(activeText, t("player.track.subtitle") || "Subtitle")
          : t("player.subtitle.off") || "Off",
      ),
      width: 300,
      selector: textSelector.length > 1 ? textSelector : [
        {
          html: t("player.subtitle.off") || "Off",
          default: true,
          onSelect() {},
        },
        {
          html: t("player.subtitle.unavailable") || "No subtitles on this stream",
          onSelect() {},
        },
      ],
    })
  }
}

function applyPreferredTracks(player: any): void {
  try {
    const audioTracks: ShakaTrack[] =
      typeof player.getAudioTracks === "function"
        ? player.getAudioTracks()
        : (player.getVariantTracks?.() || [])
    const audioIndex = findPreferredTrackIndex("audio", audioTracks)
    if (audioIndex >= 0) {
      const track = audioTracks[audioIndex]
      if (typeof player.selectAudioTrack === "function") player.selectAudioTrack(track)
      else player.selectVariantTrack?.(track, true)
    }
  } catch {}
  try {
    const textTracks: ShakaTrack[] = player.getTextTracks?.() || []
    const textIndex = findPreferredTrackIndex("subtitle", textTracks)
    if (textIndex >= 0) {
      player.selectTextTrack?.(textTracks[textIndex])
      player.setTextTrackVisibility?.(true)
    }
  } catch {}
}

function installNetworkingFilters(player: any): void {
  const engine = player.getNetworkingEngine?.()
  if (!engine?.registerRequestFilter) return
  engine.registerRequestFilter((_type: unknown, request: { uris?: string[]; headers?: Record<string, string> }) => {
    if (!Array.isArray(request.uris)) return
    request.uris = request.uris.map((uri) => {
      const upstream = unwrapStreamProxyUrl(uri)
      if (useDevStreamProxy()) {
        const headers = resolveMediaHeaders(upstream)
        Object.assign(request.headers || (request.headers = {}), devProxyFetchHeaders(headers))
        return wrapStreamUrlForDev(uri)
      }
      return uri
    })
  })
}

export async function attachShaka(
  art: any,
  video: HTMLVideoElement,
  url: string,
  opts: { live?: boolean } = {},
): Promise<ShakaHandle> {
  const mod = await import("shaka-player")
  const shaka = (mod as any).default || mod
  shaka.polyfill?.installAll?.()
  if (!shaka.Player?.isBrowserSupported?.()) {
    throw new Error("Shaka Player is not supported in this browser")
  }

  const player = new shaka.Player(video)
  installNetworkingFilters(player)
  player.configure?.({
    streaming: {
      lowLatencyMode: opts.live === true,
      rebufferingGoal: opts.live === true ? 1 : 2,
      bufferingGoal: opts.live === true ? 12 : 30,
      // Required for CEA-608/708 captions embedded in TS segments (live IPTV)
      parsePrftBox: true,
      retryParameters: {
        maxAttempts: 3,
        baseDelay: 500,
        backoffFactor: 2,
        fuzzFactor: 0.2,
        timeout: 15000,
      },
    },
    manifest: {
      retryParameters: {
        maxAttempts: 3,
        baseDelay: 500,
        backoffFactor: 2,
        fuzzFactor: 0.2,
        timeout: 15000,
      },
      hls: {
        // Must be false so Shaka parses HLS itself (not native browser) → exposes text tracks
        ignoreTextStreamFailures: true,
        // Allow Shaka to detect EXT-X-MEDIA TYPE=SUBTITLES and CEA captions
        useFullSegmentsForStartTime: opts.live === true,
      },
    },
    abr: { enabled: true },
    // On iOS WKWebView, MSE is unreliable — use native HLS player (preferNativeHls: true).
    // On all other platforms (desktop/Android), force Shaka's own HLS parser so it
    // can expose audio/subtitle tracks via its own MSE pipeline (preferNativeHls: false).
    preferNativeHls: typeof navigator !== "undefined"
      && /\b(iPad|iPhone|iPod)\b/i.test(navigator.userAgent || ""),
  })

  const refresh = () => refreshShakaTrackSettings(art, player, opts)
  player.addEventListener?.("trackschanged", refresh)
  player.addEventListener?.("variantchanged", refresh)
  player.addEventListener?.("textchanged", refresh)
  // streaming event fires once buffering starts — catches late-loaded text tracks on live
  player.addEventListener?.("streaming", () => {
    setTimeout(refresh, 300)
    setTimeout(refresh, 1500)
  })
  player.addEventListener?.("adaptation", refresh)
  player.addEventListener?.("error", (event: { detail?: unknown }) => {
    log.warn("[xt:player] Shaka error", event?.detail || event)
  })

  log.log("[xt:player] Shaka load", redactUrl(url).slice(0, 140))
  await player.load(url)
  applyPreferredTracks(player)
  refreshShakaTrackSettings(art, player, opts)
  // Extra delayed refresh for live: text tracks often arrive after first segment
  if (opts?.live) {
    setTimeout(refresh, 1000)
    setTimeout(refresh, 3000)
  }
  art.shaka = player

  return {
    player,
    async destroy() {
      try { art.shaka = null } catch {}
      try { await player.destroy?.() } catch {}
    },
  }
}
