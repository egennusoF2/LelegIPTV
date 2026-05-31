# Runtime flows

## Fork alignment flow

Files: `scripts/sync-upstream.sh`, `docs/SYNC_UPSTREAM.md`, `package.json`.

1. `pnpm sync:upstream -- --check` runs the script in read-only mode.
2. The script requires `origin` and `upstream`. If `upstream` is missing,
   `--setup-upstream` adds `https://github.com/infinitel8p/Extreme-InfiniTV.git`.
3. The script fetches both remotes, compares `upstream/main...HEAD`, compares
   `upstream/main...origin/main`, and reports ahead/behind.
4. `--apply` refuses dirty working trees.
5. Default strategy is `ff-only`; `rebase` and `merge` are explicit.
6. `--push` pushes the synced branch to `origin`.

## First-run and playlist creation flow

Files: `src/pages/login.astro`, `src/scripts/lib/creds.js`,
`src/scripts/lib/diagnostic.ts`, `src/scripts/lib/m3u-parser.ts`,
`src/scripts/lib/android-fs.js`, `src/scripts/lib/local-content.js`,
`src/scripts/lib/catalog.js`.

1. User creates an Xtream, remote M3U, or local M3U entry from `/login`.
2. Xtream inputs may be parsed from `player_api.php`/`get.php` URLs by
   `parseXtreamUrl()`.
3. `resolveServerScheme()` probes HTTP/HTTPS for Xtream credentials.
4. `resolveM3UScheme()` probes HTTP/HTTPS for remote M3U URLs.
5. Diagnostics use `runXtreamDiagnostic()` or `runM3UDiagnostic()`.
6. `addEntry()` persists the sanitized entry and selects it.
7. `addEntry()` dispatches `xt:entries-updated` and `xt:active-changed`.
8. Login may call `warmupActive()` so live/VOD/series caches exist before the
   user lands on app routes.

## Active playlist switching flow

Files: `src/components/PlaylistSwitcher.svelte`, `src/scripts/lib/creds.js`,
`src/scripts/lib/cache.js`, `src/scripts/lib/catalog.js`,
`src/scripts/lib/playlist-rows.js`.

1. `PlaylistSwitcher.svelte` reads entries with `getEntries()`.
2. Selecting an entry calls `selectEntry(id)`.
3. `selectEntry()` updates `lastUsedAt`, persists state, and dispatches
   `xt:active-changed`.
4. UI consumers reload their page-specific data on `xt:active-changed`.
5. Cache hydration may preload live/VOD/series data for the selected entry.

## Catalog warming flow

Files: `src/scripts/lib/catalog.js`, `src/scripts/lib/cache.js`,
`src/scripts/lib/xtream-api.js`, `src/scripts/lib/provider-fetch.js`,
`src/scripts/lib/m3u-parser.ts`, `src/components/CatalogWarmingIndicator.svelte`.

1. `warmupActive(playlistId, { force? })` discovers the active entry.
2. It dispatches `xt:catalog-warming-start`.
3. It warms live, VOD, and series where supported.
4. Each catalog call uses `cachedFetch()` with 24h TTL.
5. Xtream calls use `xtreamApiFetch()` and mirror failover.
6. M3U live calls fetch or read playlist text and parse it with `parseM3U()`.
7. Streaming downloads dispatch byte progress via
   `xt:catalog-warming-bytes`.
8. Per-kind status dispatches `xt:catalog-warming-progress`.
9. Completion dispatches `xt:catalog-warmed`.

## Live TV playback flow

Files: `src/pages/livetv.astro`, `src/scripts/stream/stream.ts`,
`src/scripts/lib/catalog.js`, `src/scripts/lib/epg-data.js`,
`src/scripts/lib/player-runtime.ts`, `src/scripts/lib/stream-urls.ts`,
`src/scripts/lib/stream-headers.ts`, `src/scripts/lib/preferences.js`,
`src/scripts/lib/discord-rpc.js`.

1. `/livetv` provides the DOM: virtual channel list, category picker, player,
   EPG side panel, radio view, overlays.
2. `stream.ts` loads active credentials, catalog data, preferences, and EPG.
3. Channel rows are virtualized for performance.
4. Category/search filters use normalized text and `mountCategoryPicker()`.
5. Selecting a channel builds a stream URL. Xtream URLs use
   `resolveStreamUrl()` so mirror probing can switch to a working domain.
6. Xtream live defaults to `.m3u8` unless the playlist live container is `ts`.
   A startup sentinel retries stalled `.m3u8` live playback as `.ts` when the
   stream is Xtream and no direct M3U URL is involved.
7. Headers from M3U `#EXTVLCOPT` or provider settings are applied by
   `applyStreamHeaders()`.
8. `mountPlayer()` returns embedded Video.js/Artplayer handle or external
   launcher according to `getPlayerBackend()`.
9. Embedded playback detects HLS, DASH, MPEG-TS, or native media by extension,
   MIME, or content-type probe.
10. Live recents/favorites update through `preferences.js`.
11. EPG side panel uses `effectiveTvgId()` and `getNowNext()`.
12. Discord presence is updated through `discord-rpc.js` when enabled.
13. Replay/autoplay URLs can arrive as
    `/livetv?channel=<id>&catchupStart=<epochMs>&catchupStop=<epochMs>`.
    `stream.ts` builds a catchup source via `catchup.ts` and labels the player
    state as `REC`.

## Movie playback flow

Files: `src/pages/movies/index.astro`, `src/scripts/movies/movies.ts`,
`src/pages/movies/detail.astro`, `src/scripts/movies/detail.ts`,
`src/scripts/lib/xtream-api.js`, `src/scripts/lib/stream-urls.ts`,
`src/scripts/lib/player-runtime.ts`, `src/scripts/lib/downloads.js`,
`src/scripts/lib/preferences.js`.

1. `/movies` loads VOD catalog, category map, favorites/recents/watchlist, and
   renders poster cards through `entry-card.js`.
2. Detail links go to `/movies/detail?id=<stream_id>`.
3. Detail script fetches/caches `get_vod_info`.
4. Playback URL is built with `buildMovieStreamUrl()`.
5. Embedded/external playback follows `player-runtime.ts`.
6. Progress is persisted with kind `vod`.
7. Downloads can be started from detail or context menu.

## Series playback flow

Files: `src/pages/series/index.astro`, `src/scripts/series/series.ts`,
`src/pages/series/detail.astro`, `src/scripts/series/detail.ts`,
`src/scripts/lib/preferences.js`, `src/scripts/lib/player-runtime.ts`.

1. `/series` loads series catalog and category data.
2. Poster cards include progress badges via `getSeriesProgressSummary()`.
3. Detail page fetches/caches `get_series_info`.
4. Episodes are grouped by season.
5. Episode playback uses kind `episode` progress with `seriesId`, season, and
   episode metadata.
6. Completed/progress events refresh listing badges.

## EPG loading and mapping flow

Files: `src/pages/epg.astro`, `src/scripts/epg/epg.ts`,
`src/scripts/epg/mapping.ts`, `src/scripts/lib/epg-data.js`,
`src/scripts/lib/preferences.js`, `src/scripts/lib/programme-dialog.js`.

1. EPG sources are resolved by `buildEpgUrls()`.
2. User primary override wins. Provider default is next unless disabled.
3. Additional URLs are waterfall-merged to fill missing channels only.
4. XMLTV is fetched conditionally where possible and cached.
5. XMLTV parsing runs in `epg-worker.ts` if possible.
6. Timezone offset can be inferred or manually stored per playlist.
7. `/epg` loads live channels, filters them, and renders a time-grid.
8. `mapping.ts` opens a dialog that lets users override channel-to-EPG mapping.
9. Mapping overrides are stored in `preferences.channelEpgMap`.
10. Relevant events are `xt:epg-loaded`, `xt:epg-offset-changed`, and
    `xt:channel-epg-changed`.
11. If XMLTV refresh fails but a parsed XMLTV cache row exists,
    `epg-data.js` returns the cached programme map instead of failing the whole
    load.
12. If the full XMLTV grid cannot be loaded for an Xtream-capable playlist,
    `/epg` falls back to per-channel Xtream EPG endpoints for visible channels:
    first `get_short_epg`, then `get_simple_data_table`.
13. `/livetv` side-panel EPG uses per-channel APIs directly, so a full `/epg`
    XMLTV error does not prove the provider has no guide data.
14. Replayable ended programmes are marked `REC`; clicking the programme
    dialog CTA navigates to Live TV with `catchupStart`/`catchupStop`.

## Settings flow

Files: `src/pages/settings.astro`, `src/scripts/settings/settings_effects.ts`,
`src/scripts/lib/app-settings.js`, settings Svelte components in
`src/components`.

Settings page coordinates many domains:

- playlist CRUD through `creds.js`
- category visibility through `HiddenCategoriesEditor.svelte`
- locale through `LocalePicker.svelte`
- favorites order through `FavoritesReorder.svelte`
- hub strips through `HubStripsEditor.svelte`
- player backend/path/args through `PlayerPicker.svelte`
- TV overscan through `TvOverscanCard.svelte`
- close-to-tray through `CloseToTrayCard.svelte`
- connection limits through `ConnectionLimitBanner.svelte`
- backup import/export through `backup.js`
- app update checks through Tauri updater
- downloads folder scanning through `downloads.js`
- Discord settings through `discord-rpc.js`/`app-settings.js`

## Downloads flow

Files: `src/pages/downloads.astro`, `src/scripts/lib/downloads.js`,
`src/scripts/lib/android-fs.js`, `src/scripts/lib/provider-fetch.js`,
`src/scripts/lib/app-settings.js`.

1. User starts downloads from movie/series detail or poster menus.
2. `startDownload()` creates an item in persisted download state.
3. `tryRunNext()` respects configured concurrency.
4. Desktop uses Tauri filesystem APIs and selected download directory.
5. Android uses Android filesystem APIs and content URI helpers.
6. Progress dispatches `xt:download-progress`.
7. List changes dispatch `xt:downloads-changed`.
8. Throughput timer dispatches `xt:throughput-tick`.

## External player flow

Files: `src/scripts/lib/player-runtime.ts`,
`src/scripts/lib/external-player-button.ts`,
`src/components/PlayerPicker.svelte`, `src-tauri/src/external_player.rs`.

1. User selects backend `mpv` or `vlc` and configures a binary path.
2. Frontend builds argv with `buildMpvArgs()` or `buildVlcArgs()`.
3. Tauri command `launch_external_player` receives path, args, mode, and reuse.
4. `mode: "detect"` probes `--version`.
5. `mode: "exists"` validates a path.
6. `mode: "launch"` spawns or reuses the external player.
7. MPV reuse uses JSON IPC socket/pipe and `loadfile`.
8. VLC reuse uses one-instance options and pid tracking.
9. Errors are prefixed `NOT_FOUND`, `PERMISSION`, `TIMEOUT`, `OTHER`.

## Tray and native desktop flow

Files: `src-tauri/src/tray.rs`, `src/scripts/lib/tray-handler.ts`,
`src/scripts/lib/app-settings.js`, `src/layouts/Layout.astro`.

1. Tauri desktop installs tray icon at startup.
2. Tray menu can show/hide the window or navigate to routes.
3. Navigation is emitted as `xt:tray:navigate`.
4. Frontend handler receives route and updates browser location.
5. Close-to-tray default is enabled; user setting syncs to Rust command
   `set_close_to_tray`.

## Backup and restore flow

Files: `src/scripts/lib/backup.js`, `src/pages/settings.astro`,
`src/scripts/lib/creds.js`, `src/scripts/lib/preferences.js`,
`src/scripts/lib/app-settings.js`.

1. Export snapshots playlist state, preferences, and selected app settings.
2. Import validates backup format name/version.
3. Import restores credentials, prefs, and settings through owning modules.
4. Restore dispatches normal change events through those modules.
5. Backup paths must avoid browser-only assumptions on Android/Tauri.
