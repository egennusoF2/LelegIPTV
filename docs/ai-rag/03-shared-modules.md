# Shared module contracts

## `creds.js` contract

Path: `src/scripts/lib/creds.js`

Owned data:

```ts
{
  entries: PlaylistEntry[],
  selectedId: string
}
```

Playlist entry variants:

- Xtream: `_id`, `title`, `type: "xtream"`, `serverUrl`, `username`,
  `password`, `mirrors`, `liveContainer`, `epgUrl`, `additionalEpgUrls`,
  `disableProviderEpg`, `addedAt`, `lastUsedAt`.
- Remote M3U: `_id`, `title`, `type: "m3u"`, `url`, EPG fields, timestamps.
- Local M3U: `_id`, `title`, `type: "local-m3u"`, `sourceName`, EPG fields,
  timestamps. Content is stored separately by `local-content.js`.

Important exports:

- `getState()`, `getEntries()`, `getActiveEntry()`
- `addEntry()`, `selectEntry()`, `removeEntry()`, `updateEntry()`
- `restoreState()`, `refreshActive()`
- `loadCreds()` returns the compatibility flat shape `{ host, port, user, pass,
  liveContainer }`
- `fmtBase()`, `safeHttpUrl()`, `buildApiUrl()`
- `isLikelyM3USource()`, `isLocalM3UHost()`, `readLocalM3UContent()`
- `parseXtreamUrl()`, `resolveServerScheme()`, `resolveM3UScheme()`
- `xtreamCandidatesFor()`, `getMirrorPin()`, `setMirrorPin()`,
  `clearMirrorPin()`

Events:

- `xt:entries-updated`
- `xt:active-changed`

RAG keywords: playlist storage, active playlist, Xtream credentials, M3U URL,
local M3U, mirror failover, migration, player_api URL, scheme probe.

## `catalog.js` contract

Path: `src/scripts/lib/catalog.js`

Responsibilities:

- Fetch live/VOD/series catalogs for active playlist.
- Normalize provider-specific records into UI-friendly item arrays.
- Cache results through `cache.js`.
- Parse M3U live channels.
- Carry catchup/replay metadata from providers into live channel records.
- Emit warming/progress events for global UI.

Exports:

- `ensureLive(creds, playlistId, opts)`
- `ensureVod(creds, playlistId, opts)`
- `ensureSeries(creds, playlistId, opts)`
- `warmupActive(playlistId, opts)`
- `retryWarmupKind(playlistId, kind)`
- Event constants for warmed/warming.

Cache kinds:

- `live` for Xtream live.
- `m3u` for M3U live.
- `vod` for movies.
- `series` for series.

Events:

- `xt:catalog-warming-start`
- `xt:catalog-warming-progress`
- `xt:catalog-warming-bytes`
- `xt:catalog-warmed`

Rules:

- Use `xtreamApiFetch()` for Xtream API calls.
- Use `providerFetch()` for provider/M3U network calls.
- Use `retryWithBackoff()` for transient provider failures.
- VOD/series return empty arrays for M3U-only playlists.
- Filter likely M3U group-marker pseudo channels such as `----Italia----`.
- Xtream `tv_archive` / `tv_archive_duration` map to `catchup: "xtream"` and
  `catchupDays`.
- M3U live records preserve `catchup`, `catchupDays`, and `catchupSource` from
  `m3u-parser.ts`.

## `cache.js` contract

Path: `src/scripts/lib/cache.js`

Responsibilities:

- Memory cache for current runtime.
- IndexedDB persistent cache named `xt_cache`.
- TTL-aware `cachedFetch()` wrapper.
- Entry/kind invalidation and lazy pruning.

Data shape per cache entry:

```ts
{
  data: unknown,
  fetchedAt: number,
  ttl: number
}
```

Important exports:

- `hydrate(entryId, kind)`
- `getCached(entryId, kind)`
- `setCached(entryId, kind, data, ttl?)`
- `cachedFetch(entryId, kind, ttl, loader, opts?)`
- `invalidateEntry(entryId)`
- `invalidatePrefix(entryId, prefix)`
- `clearAll()`

Event:

- `xt:cache-revalidated` with `{ entryId, kind }`.

Rules:

- Do not store secrets here.
- Cache keys must be playlist-scoped.
- Call `hydrate()` before assuming cached data is available after navigation.

## `epg-data.js` contract

Path: `src/scripts/lib/epg-data.js`

Responsibilities:

- Resolve ordered XMLTV source URLs.
- Fetch XMLTV with conditional HTTP metadata.
- Detect gzip and parse XMLTV.
- Merge primary/additional EPG sources.
- Infer and store timezone offset.
- Resolve channel EPG IDs using tvg-id, override, or name matching.
- Reuse parsed XMLTV cache when a refresh fails.

Important exports:

- `buildEpgUrlsFromEntry()`, `buildEpgUrls()`
- `mergeProgrammeMaps()`, `mergeChannelNameMaps()`
- `parseXmlTvDate()`, `parseXmlTv()`
- `getNowNext()`, `inferTimezoneOffsetMin()`
- `getOffsetSetting()`, `setOffsetSetting()`
- `detectGzip()`
- `loadProgrammes(playlistId, creds, opts)`
- `getProgrammesSync(playlistId)`, `invalidateEpgPlaylist(playlistId)`
- `resolveTvgId()`, `effectiveTvgId()`, `classifyTvgIdSource()`
- `getAvailableEpgChannels()`
- `testEpgSource(url, opts)`

Events:

- `xt:epg-loaded`
- `xt:epg-offset-changed`
- `xt:epg-source-status`

Source precedence:

1. `entry.epgUrl` primary override.
2. Provider default unless `disableProviderEpg`.
3. `additionalEpgUrls` waterfall additions.

Rules:

- Additional EPG sources fill missing tvg-id keys only.
- `channelEpgMap` from preferences can override channel mapping.
- Worker parsing is preferred but fallback must remain functional.
- Provider XMLTV feeds may include `DOCTYPE` or inline `ENTITY` declarations.
  The parser strips those declarations and neutralizes custom entity references
  before `DOMParser`; standard XML entities remain supported. Do not restore a
  hard rejection for `DOCTYPE` without another safe XML parsing strategy.
- A full XMLTV failure is not equivalent to "no EPG". Live TV may still have
  per-channel Xtream EPG through `get_short_epg`.

## `catchup.ts` contract

Path: `src/scripts/lib/catchup.ts`

Responsibilities:

- Determine if a channel/programme pair can be replayed.
- Enforce replay window using `catchupDays` with a conservative default.
- Build Xtream catchup URLs using `/timeshift/<user>/<pass>/<duration>/<start>/<stream_id>`.
- Build M3U catchup URLs from `catchup-source` placeholders or append-style
  `utc`/`lutc` query parameters.

Important exports:

- `channelHasCatchup(channel)`
- `canReplayProgramme(channel, programme, now?)`
- `buildCatchupStreamUrl(channel, programme, creds?)`

Data contracts:

- Channel fields: `id`, `url`, `catchup`, `catchupDays`, `catchupSource`.
- Programme fields: `start`, `stop` in epoch milliseconds.
- Xtream credentials: `host`, `port`, `user`, `pass`, optional
  `liveContainer`.

Rules:

- Only ended programmes can be replayed.
- Future/current programmes use normal live playback.
- Xtream start is formatted as local `YYYY-MM-DD:HH-mm`.
- Use `.ts` for timeshift only when `creds.liveContainer === "ts"`;
  otherwise use `.m3u8`.

RAG keywords: catchup, replay, registrato, timeshift, tv_archive,
tv_archive_duration, catchup-source, catchup-days, utc, lutc.

## `preferences.js` contract

Path: `src/scripts/lib/preferences.js`

Responsibilities:

- Per-playlist user preferences and playback state.
- Tauri store plus localStorage/cookie mirror.
- Backup/restore snapshots.

Feature buckets:

- Favorites: live, vod, series.
- Favorite metadata and ordering.
- Watchlist: vod, series only.
- Recents: live, vod, series.
- Progress: vod and episode.
- Hidden/allowed categories and category mode.
- EPG sync and channel-to-EPG overrides.
- View sort.

Important exports:

- Favorites: `getFavorites`, `isFavorite`, `toggleFavorite`,
  `getFavoritesOrdered`, `setFavoritesOrder`, `moveFavorite`,
  `getGlobalFavorites`, `getAllGlobalFavorites`.
- Watchlist: `getWatchlist`, `isOnWatchlist`, `toggleWatchlist`,
  `getAllGlobalWatchlist`.
- Recents: `getRecents`, `pushRecent`, `clearRecent`.
- Progress: `getProgress`, `setProgress`, `markCompleted`, `clearProgress`,
  `getContinueWatching`, `getSeriesProgressSummary`.
- Categories: `getHiddenCategories`, `setCategoryHidden`,
  `filterVisibleCategories`, `getAllowedCategories`, `setAllowedCategories`,
  `getCategoryMode`, `setCategoryMode`.
- EPG mapping: `getSyncEpgWithLive`, `setSyncEpgWithLive`,
  `getChannelEpgMap`, `getChannelEpgOverride`, `setChannelEpgOverride`.
- Sort: `getViewSort`, `setViewSort`.
- Backup: `snapshotPrefs`, `restorePrefs`.

Events:

- `xt:favorites-changed`
- `xt:watchlist-changed`
- `xt:recents-changed`
- `xt:progress-changed`
- `xt:hidden-categories-changed`
- `xt:allowed-categories-changed`
- `xt:category-mode-changed`
- `xt:epg-sync-changed`
- `xt:channel-epg-changed`
- `xt:favorites-order-changed`
- `xt:view-prefs-changed`

Rules:

- Always include `playlistId` and `kind` in relevant event details.
- Watchlist excludes live channels by design.
- Retention days are read from `app-settings.js`.

## `app-settings.js` contract

Path: `src/scripts/lib/app-settings.js`

Responsibilities:

- Global app settings in localStorage.
- Emit events and update immediate DOM/native side effects.

Settings:

- User agent override.
- Download directory and concurrency.
- Performance mode.
- TV overscan.
- Close-to-tray.
- Hub strip configuration.
- Continue Watching progress retention.
- Discord Rich Presence settings.
- Player backend/path/args/reuse.

Events:

- `xt:settings-changed`
- `xt:perf-mode-changed`
- `xt:progress-retention-changed`
- `xt:player-backend-changed`
- `xt:close-to-tray-changed`
- `xt:hub-strips-changed`
- `xt:tv-overscan-changed`
- `xt:discord-rpc-changed`

Rules:

- First-paint settings mirrored in `Layout.astro` must stay in sync.
- Close-to-tray must also call the Rust `set_close_to_tray` command.
- Player external settings affect `player-runtime.ts` and `PlayerPicker.svelte`.

## `provider-fetch.js` contract

Path: `src/scripts/lib/provider-fetch.js`

Responsibilities:

- Central network path for IPTV provider calls.
- Prefer Tauri HTTP plugin where browser CORS/WebView behavior can fail.
- Apply app-level User-Agent override.
- Provide `streamingText()` for progress reporting.
- Track provider stats for playlist health.

Important exports:

- `providerFetch(url, init)`
- `streamingText(response, onProgress)`
- `getProviderStats()`

Rules:

- Avoid raw `fetch` for provider URLs unless code is deliberately browser-only.
- Redact URLs when logging failures.

## `xtream-api.js` contract

Path: `src/scripts/lib/xtream-api.js`

Responsibilities:

- Build action URLs from active Xtream entry.
- Sequentially try primary and mirror credentials.
- Pin successful mirror index in `creds.js`.
- Probe stream URLs for mirror failover.

Important exports:

- `xtreamApiFetch(action, params, opts)`
- `resolveStreamUrl(buildUrl)`

Rules:

- Failover includes 4xx intentionally because providers can vary credentials by
  mirror.
- All-failed state is throttled briefly to avoid long repeated mirror loops.
- Mirror pins clear on `xt:entries-updated`.

## `player-runtime.ts` contract

Path: `src/scripts/lib/player-runtime.ts`

Responsibilities:

- Unified embedded/external playback surface.
- MPV/VLC argv builders.
- Tauri external player launch.
- Android external handoff.
- Video.js/Artplayer/HLS/DASH/mpegts mounting.

Important exports:

- Types: `PlayerBackend`, `ExternalPlayerKind`, `Mounted`, `VjsLikeHandle`.
- Backend gates: `externalPlayersAvailable`, `androidExternalAvailable`.
- Args: `buildMpvArgs`, `buildVlcArgs`, `buildArgsFor`.
- Errors: `PlayerNotConfiguredError`, `PlayerLaunchError`,
  `AndroidHandoffError`.
- Launchers: `getExternalLauncher`, `getAndroidHandoffLauncher`,
  `openStreamInAndroidPackage`.
- Detection/mount: `detectPlayer`, `mountPlayer`, `isExternalBackend`.

Event:

- `xt:player-fallback` when playback backend falls back.

Rules:

- Keep argv builders pure and tested.
- External player paths come from `app-settings.js`.
- Android path uses JavaScript bridge, not desktop Tauri process launch.
- Stream kind detection prefers URL extension and MIME, then probes
  Content-Type for extensionless URLs.
- Embedded players support HLS `.m3u8`, DASH `.mpd` via `dashjs`, raw
  MPEG-TS `.ts` via `mpegts.js`, and native browser media.
- Destroy active HLS/DASH/MPEG-TS handles before switching stream types.

## `downloads.js` contract

Path: `src/scripts/lib/downloads.js`

Responsibilities:

- Persist and manage download queue.
- Use Tauri FS or Android FS depending on platform.
- Convert local files to playable sources.
- Maintain throughput history.
- Send completion notifications.

Important exports:

- `listDownloads()`, `isDownloadable()`
- `getLocalPlayableSrc(remoteUrl)`
- `tryAndroidIntentPlayback(remoteUrl)`
- `startDownload({ url, title, ext, source })`
- `resumeDownload`, `pauseDownload`, `cancelDownload`, `removeDownload`
- `clearFinishedDownloads`, `pruneMissingDownloads`, `scanDownloadsFolder`
- Throughput history getters.

Events:

- `xt:downloads-changed`
- `xt:download-progress`
- `xt:throughput-tick`

Rules:

- Honor concurrency from `app-settings.js`.
- Download paths must be valid for platform.
- Sidecar metadata supports scan/recovery.

## UI helper modules

`category-picker.ts`: reusable category dialog/controller. Owns active category
storage, pseudo rows, hidden/allowed mode integration, search, and event
dispatch.

`entry-card.ts`: builds poster cards with favorite/watchlist affordances and
context menu hooks.

`poster-menu.ts`: movie/series context menu for open, favorite, watchlist,
download, copy stream URL.

`dialog-spatial-nav.ts`: focus trap/spatial navigation helper for dialogs and
popovers.

`focus-glide.ts`: animated focus ring for keyboard/TV. Suppressed in perf mode.

`toast.ts`: toast UI.

`programme-dialog.js`: EPG programme detail dialog. Shows normal "watch now"
for live programmes and replay/recording CTA when `canReplay` is true for an
ended programme.

`confirm-dialog.ts`: reusable confirmation dialog.

`morph-detail.ts`: detail-page visuals and poster fallback.

`external-player-button.ts`: escape-hatch button for opening current stream in
external player or Android app.

`player-picker-dialog.ts`: Android video player selection dialog.

`stream-diagnostic-dialog.js`: UI around stream diagnostics.

## Diagnostics and support modules

`diagnostic.ts`: connection diagnostics for Xtream/M3U sources.

`stream-diagnostic.js`: stream/HLS diagnostic engine.

`provider-error.js`: provider error classifier and renderer.

`playlist-health.ts`: playlist health summary from cache, account, EPG, and
provider stats.

`playlist-rows.js`: playlist row renderer and health presentation.

`account-info.js`: user info, expiration, connection limit cache.

`retry.ts`: retry/backoff primitives.

`log.ts`: logging and URL redaction.

`changelog.ts`: GitHub release fetching and markdown sanitization.

`backup.js`: import/export of settings, playlist, and preferences.

## Platform helpers

`android-fs.js`: Android filesystem/content URI helper.

`tray-handler.ts`: frontend Tauri tray event handler.

`discord-rpc.js`: frontend Discord IPC bridge.

`external-link.ts`: safe external URL opener.

`clipboard.ts`: clipboard abstraction.

`notify.ts`: notification abstraction.

`connectivity.ts`: reconnect detection and refresh behavior.
