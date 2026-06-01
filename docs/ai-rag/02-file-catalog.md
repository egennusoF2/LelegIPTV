# File-by-file catalog

This catalog gives each relevant file a compact retrieval chunk. Use it to
answer "where is this behavior implemented?" and "what should I read before
editing?".

## Root maintenance files

### `scripts/sync-upstream.sh`

Fork alignment script. Fetches `origin` and `upstream`, reports local/fork
ahead-behind status against `upstream/main`, and can apply updates with
`ff-only`, `rebase`, or `merge`. Refuses dirty `--apply`, never force-pushes,
can add default upstream remote.

### `package.json`

Defines package metadata, dependencies, and scripts. Important scripts:
`dev`, `build`, `preview`, `tauri`, `tauri:android`, `test`, `lint`,
`screenshots`, `sync:upstream`. Package manager is `pnpm@10.31.0`.

### `astro.config.mjs`

Astro/Vite config. Adds Tailwind and Svelte integrations, icon import optimizer,
LAN HMR via `XTREAM_HMR_HOST`, optimizeDeps for Tauri plugins, and chunk warning
limit.

### `svelte.config.js`

Svelte config for Astro/Svelte integration. Read before changing Svelte compiler
behavior.

### `eslint.config.js`

ESLint flat config for JS/TS/Astro/Svelte. No Prettier pipeline is declared.

### `tsconfig.json`

Strict TypeScript config extending Astro strict settings. Defines `@/*` alias to
`src/*`.

### `vitest.config.ts`

Vitest config for tests. Read before adding browser-like tests or aliases.

### `mise.toml`

Tool version hints for local development.

## Layout and global UI

### `src/layouts/Layout.astro`

Primary app shell. Loads global CSS, sidebar, title bar, resize edges, and
catalog warming indicator. Contains first-paint inline script for splash state,
font scale, platform detection, perf mode, TV overscan, locale direction,
cached translations, theme, and Android status bar. Edits here can affect every
route and build-time safety.

### `src/styles/global.css`

Global Tailwind import, design tokens, CSS variables, themes, focus styles,
safe-area/overscan layout, app shell styling, player styling, skeletons, cards,
dialogs, TV/perf-mode rules. Check this before changing visual primitives.

### `src/types/globals.d.ts`

Ambient declarations for globals such as Tauri/Android bridge objects. Update
when adding runtime globals used by TypeScript.

### `src/plugins/vite-plugin-optimize-tabler-icons.ts`

Vite plugin that optimizes Tabler icon imports. Touch only when changing icon
bundling or dependency behavior.

## Astro app routes

### `src/pages/index.astro`

Home/hub route. Uses `HubStrips.svelte` and `WelcomeCard.astro`. Inline script
checks first-run playlist state, loads recents/catalog/EPG previews, injects
version, listens to playlist and catalog events, and updates tile art.

### `src/pages/livetv.astro`

Live TV route DOM. Provides channel list, category picker, search, video player,
radio display, EPG side panel, diagnostic/context affordances. Runtime behavior
lives in `src/scripts/stream/stream.ts`.

### `src/pages/epg.astro`

Full schedule grid route DOM. Provides category/search controls, refresh/now
buttons, EPG grid containers, and channel mapping dialogs. Runtime behavior:
`src/scripts/epg/epg.ts` and `src/scripts/epg/mapping.ts`.

### `src/pages/movies/index.astro`

Movies/VOD listing route DOM. Provides search, sort, category picker, status,
and poster grid. Runtime behavior lives in `src/scripts/movies/movies.ts`.

### `src/pages/movies/detail.astro`

Movie detail/playback route DOM. Runtime behavior lives in
`src/scripts/movies/detail.ts`. Injects version.

### `src/pages/series/index.astro`

Series listing route DOM. Provides search, sort, category picker, status, and
poster grid. Runtime behavior lives in `src/scripts/series/series.ts`.

### `src/pages/series/detail.astro`

Series detail and episode playback route DOM. Runtime behavior lives in
`src/scripts/series/detail.ts`. Injects version.

### `src/pages/favorites.astro`

Cross-playlist favorites route. Mounts `AllFavoritesView.svelte` and injects
version.

### `src/pages/watchlist.astro`

Cross-playlist watchlist route. Mounts `AllWatchlistView.svelte` and injects
version.

### `src/pages/recently-added.astro`

Recently-added route. Mounts `RecentlyAddedView.svelte` and injects version.

### `src/pages/search.astro`

Global search route. Mounts `SearchView.svelte`.

### `src/pages/settings.astro`

Large settings route. Owns playlist management UI, category/filter controls,
locale, favorites ordering, hub strips, player backend settings, downloads,
backup/restore, updater, Discord settings, EPG settings, account info, and
native integration controls. Uses many `src/scripts/lib` modules and several
Svelte settings components. Highest-risk page for broad regressions.

### `src/pages/downloads.astro`

Downloads manager route. Renders download rows, progress controls, pruning,
folder scanning, Android URI display, and dialog spatial navigation. Runtime
logic imports `downloads.js`, app settings, Android FS helpers, i18n, and
version injection.

### `src/pages/login.astro`

Playlist setup/login route. Handles Xtream credentials, remote M3U, local M3U,
scheme probing, diagnostics, EPG source tests, Android file picking, and initial
catalog warmup. Uses `creds.js`, `m3u-parser.ts`, `diagnostic.ts`, `epg-data.js`,
`android-fs.js`, and i18n.

### `src/pages/docs.astro`

In-app docs entry route using the main app layout. Distinct from the standalone
docs site under `docs/`.

## Components

### `src/components/Sidebar.astro`

Main navigation sidebar. Includes playlist switcher, navigation links, download
actions/indicators, and catalog refresh affordance. Listens to app events for
state refresh.

### `src/components/TitleBar.astro`

Custom desktop title bar with window controls. Uses Tauri window API when
available. Desktop-only behavior must guard web/Android.

### `src/components/WindowResizeEdges.astro`

Invisible resize edges for custom desktop window chrome. Uses Tauri window API.

### `src/components/SearchInput.astro`

Reusable search input and clear button markup with i18n attributes.

### `src/components/SortMenu.astro`

Reusable sort menu markup for movie/series listing pages. Runtime integration
uses `sort-menu.ts`.

### `src/components/CategoryPickerDialog.astro`

Reusable category picker dialog markup. Mounted by `category-picker.ts`.

### `src/components/WelcomeCard.astro`

First-run/empty-state welcome UI used by home and Live TV.

### `src/components/PlaylistSwitcher.svelte`

Playlist picker in sidebar. Reads entries, active entry, playlist health rows,
hydrates caches, selects entries, listens to `xt:active-changed`,
`xt:entries-updated`, `xt:catalog-warmed`, and locale changes.

### `src/components/CatalogWarmingIndicator.svelte`

Global catalog warmup progress indicator. Listens to
`xt:catalog-warming-start`, `xt:catalog-warming-progress`,
`xt:catalog-warming-bytes`, `xt:catalog-warmed`. Can retry failed warmup kinds.

### `src/components/ConnectionLimitBanner.svelte`

Banner for Xtream account connection limit warnings. Reads active/maximum
connection info from `account-info.js`, refreshes on active playlist changes.

### `src/components/LocalePicker.svelte`

Settings locale selector. Uses `i18n.ts` locale APIs and dispatch/listens to
locale change state.

### `src/components/PlayerPicker.svelte`

Settings external/embedded player picker. Reads/writes player backend, paths,
extra args, reuse flags; can detect/test MPV/VLC via `player-runtime.ts` and
Tauri command.

### `src/components/CloseToTrayCard.svelte`

Settings card for desktop close-to-tray preference. Reads/writes
`app-settings.js` and syncs to Rust tray command.

### `src/components/TvOverscanCard.svelte`

Settings card for TV safe-area overscan. Reads/writes `app-settings.js` and
updates root CSS variables.

### `src/components/HiddenCategoriesEditor.svelte`

Settings editor for hidden/allowed categories and category filter mode per
kind. Uses `preferences.js`, active playlist, and `kinds.ts`.

### `src/components/FavoritesReorder.svelte`

Settings editor for favorite ordering. Reads cached catalogs and
`preferences.js` favorite order APIs.

### `src/components/HubStripsEditor.svelte`

Settings editor for home-page strip order/visibility. Uses hub strip APIs in
`app-settings.js`.

### `src/components/HubStrips.svelte`

Home page strip orchestrator. Renders configured strip types such as continue
watching, favorites, watchlist, recently added.

### `src/components/ContinueWatching.svelte`

Home strip for playback progress. Reads active playlist, preferences progress,
catalog cache, and locale.

### `src/components/FavoritesStrip.svelte`

Home strip for active-playlist favorites. Uses `preferences.js`, cache, and
kind labeling.

### `src/components/WatchlistStrip.svelte`

Home strip for active-playlist watchlist. Uses `preferences.js`, cache, and
kind labeling.

### `src/components/RecentlyAddedStrip.svelte`

Home strip for recently-added VOD/series from cached catalogs.

### `src/components/AllFavoritesView.svelte`

Favorites route component. Aggregates favorites across playlists, allows
switching active playlist via `selectEntry()`, hydrates caches, and renders
kind-aware links.

### `src/components/AllWatchlistView.svelte`

Watchlist route component. Aggregates watchlist across playlists, allows
playlist switching, hydrates caches, and renders kind-aware links.

### `src/components/RecentlyAddedView.svelte`

Recently-added route component. Reads active playlist, ensures catalog warmup
where needed, then renders recent VOD/series entries.

### `src/components/SearchView.svelte`

Global search component. Loads active playlist catalogs and EPG data, builds a
search index, listens to catalog warmed and active playlist events.

## Page runtime scripts

### `src/scripts/stream/stream.ts`

Live TV controller. Handles virtual channel list, search/category filtering,
numeric remote input, channel context menu, stream diagnostics, EPG panel,
radio mode, embedded/external playback, stall/buffering overlays, favorites,
recents, Discord presence, M3U parsing compatibility, and active playlist
reloads. Core route script for `/livetv`. Also owns replay entry from
`catchupStart`/`catchupStop` query params, starts recorded playback through
`catchup.ts`, and retries Xtream `.m3u8` live startup as `.ts` when appropriate.

### `src/scripts/movies/movies.ts`

Movies listing controller. Loads VOD catalog/category map, renders paginated
poster grid, handles search, sort, favorites, watchlist, recents, category
filters, context menu, provider errors, cache revalidation, active playlist
changes.

### `src/scripts/movies/detail.ts`

Movie detail/playback controller. Fetches/caches VOD info, paints poster and
metadata, controls favorite/watchlist/resume UI, mounts embedded player or
launches external player, records progress, handles downloads, PiP, Discord,
and active playlist reloads.

### `src/scripts/series/series.ts`

Series listing controller. Similar to movies listing with series-specific
progress badges, episode summary, category/search/sort, favorites/watchlist,
recents, cache revalidation, active playlist changes.

### `src/scripts/series/detail.ts`

Series detail and episode playback controller. Fetches/caches series info,
groups seasons/episodes, starts selected episodes, stores episode progress,
updates favorite/watchlist UI, supports downloads, PiP, external players,
Discord, and resume routing.

### `src/scripts/epg/epg.ts`

Full EPG grid controller. Loads live channels, XMLTV programmes, category
filters, favorites/recents pseudo categories, manual refresh, now scroll,
programme dialog, and grid rendering with timeline constants. If the full XMLTV
source cannot load, it can populate a limited Xtream grid by calling
`get_short_epg` and then `get_simple_data_table` for visible channels. Marks
replayable ended cells with `REC`.

### `src/scripts/epg/mapping.ts`

Channel-to-EPG mapping dialog. Lists live channels virtually, filters mapped
state, opens EPG channel picker, writes overrides to preferences, and listens to
active playlist, EPG loaded, channel mapping, and locale events.

### `src/scripts/settings/settings_effects.ts`

Settings UI polish script. Handles animated pills, nav rail state, commit
triggers, and visual feedback in settings. No exported API.

### `src/scripts/spatial-navigation.js`

Spatial navigation polyfill used for TV/D-pad/keyboard focus movement. Emits
prefixed navigation events and makes focusable areas navigable. High-risk for
TV UX.

### `src/scripts/version.js`

Injects app/version string into DOM where needed. Uses Tauri app API when
available and logs failures.

### `src/scripts/expiration.ts`

Injects account expiration information into UI targets, formatting days left.

### `src/scripts/updater-startup.js`

Startup auto-update check for Tauri desktop. Uses updater/process plugins and
guards frequency/availability.

### `src/scripts/capture-screenshots.mjs`

Playwright screenshot automation for docs/readme assets. Uses environment file
inputs and routes through the app.

### `src/scripts/make-latest-json.mjs`

Release helper for generating updater/latest JSON metadata.

## Shared library modules

### `src/scripts/lib/creds.js`

Playlist storage and URL helpers. Owns playlist state shape, migration from
legacy flat creds, active entry selection, add/update/remove/restore, Xtream
mirror sanitization and pinning, local M3U sentinel, `loadCreds()`, API URL
builders, HTTP URL validation, Xtream/M3U scheme probing. Dispatches
`xt:entries-updated` and `xt:active-changed`.

### `src/scripts/lib/catalog.js`

Catalog fetch/parse/cache layer. Exports `ensureLive`, `ensureVod`,
`ensureSeries`, `warmupActive`, retry warmup helpers, and catalog warming event
constants. Converts Xtream/M3U data into normalized UI lists.

### `src/scripts/lib/cache.js`

IndexedDB catalog cache plus memory layer. Exports hydrate/get/set/cachedFetch
and invalidation helpers. Emits `xt:cache-revalidated`. Prunes entries older
than 30 days lazily.

### `src/scripts/lib/epg-data.js`

XMLTV/EPG data layer. Resolves source URLs, fetches conditionally, detects gzip,
parses XMLTV, merges multiple sources, stores offsets, resolves `tvg-id`, offers
name matching and available-channel helpers, tests EPG URLs, and reuses cached
parsed XMLTV when refresh fails. Emits
`xt:epg-loaded`, `xt:epg-offset-changed`, `xt:epg-source-status`.

### `src/scripts/lib/epg-worker.ts`

Worker-side XMLTV parsing helper for `epg-data.js`. Keeps large parsing work
off main thread when Worker and DOMParser are available.

### `src/scripts/lib/preferences.js`

Per-playlist preferences store. Owns favorites, favorite metadata/order,
watchlist, recents, playback progress, completed state, Continue Watching,
hidden/allowed categories, category modes, EPG sync, channel EPG overrides,
view sort, backup snapshot/restore. Emits many `xt:*` preference events.

### `src/scripts/lib/app-settings.js`

Global settings store in localStorage. Owns user agent, download dir/concurrency,
performance mode, TV overscan, close-to-tray, hub strip ordering, progress
retention, Discord settings, player backend/path/args/reuse. Emits settings,
perf, player, tray, hub, overscan, retention, and Discord events.

### `src/scripts/lib/provider-fetch.js`

Provider network abstraction. Chooses Tauri HTTP fetch when useful/available,
applies user agent, streams text with progress, tracks provider success/failure
stats. Use for IPTV provider calls instead of raw `fetch`.

### `src/scripts/lib/xtream-api.js`

Xtream `player_api.php` wrapper. Builds URLs from active entry, tries primary
and mirrors, pins working mirror, notices failover, rate-limits all-failed retry
behavior, and resolves stream URLs with cheap probe fallback.

### `src/scripts/lib/player-runtime.ts`

Playback abstraction. Detects embedded/external/Android options, builds MPV/VLC
args, launches Tauri external players, opens Android intents, detects stream
kind, mounts Video.js/Artplayer/HLS/DASH/mpegts, and returns a unified mounted
player handle. HLS uses Video.js/Hls.js, DASH uses `dashjs`, MPEG-TS uses
`mpegts.js`, and native browser media falls back to the underlying video
element.

### `src/scripts/lib/stream-urls.ts`

Pure stream URL builders for live, movies, and episodes. Uses `fmtBase()` from
`creds.js`. Keep URL construction here for tests and consistency.

### `src/scripts/lib/stream-headers.ts`

Applies per-stream headers/user-agent/referrer behavior for playback requests,
including M3U header metadata.

### `src/scripts/lib/m3u-parser.ts`

M3U/M3U8 parser. Extracts entries, names, logos, tvg IDs, categories, radio
markers, stream URLs, header options such as `x-tvg-url` and VLC opts. Also
parses replay metadata: `catchup`, `catchup-days`, `timeshift-days`, and
`catchup-source`. Covered by fixture tests.

### `src/scripts/lib/catchup.ts`

Replay/catchup helper. Decides if an ended programme can be replayed and builds
recorded-stream URLs for Xtream `/timeshift/...` or M3U catchup-source/append
formats. Used by `/livetv`, `/epg`, and `programme-dialog.js` flows.

### `src/scripts/lib/downloads.js`

Download manager. Owns download state, filesystem writes, Android FS path,
queue/concurrency, pause/resume/cancel/remove, sidecar metadata, throughput
history, notifications, local playable source conversion, folder scan/prune.
Emits `xt:downloads-changed`, `xt:download-progress`, `xt:throughput-tick`.

### `src/scripts/lib/android-fs.js`

Wrapper for `tauri-plugin-android-fs-api`. Handles Android URI picking,
serialization/deserialization, content reads/writes, directory release, and URI
display helpers. Guard for non-Android.

### `src/scripts/lib/local-content.js`

IndexedDB storage for local M3U file text. Keeps large playlist content out of
main playlist JSON.

### `src/scripts/lib/account-info.js`

Fetches/caches Xtream user/account info. Exposes expiration, connection limits,
active playlist ID sync, and warning helpers. Emits `xt:user-info-loaded`.

### `src/scripts/lib/playlist-health.ts`

Computes playlist health summaries from account info, catalog cache, EPG cache,
and provider stats. Used by playlist rows/settings.

### `src/scripts/lib/playlist-rows.js`

Renders playlist row UI and playlist health details. Also provides empty-copy
helper and diagnostics affordance.

### `src/scripts/lib/diagnostic.ts`

Runs Xtream and M3U diagnostics. Produces structured diagnostic steps and
renders results. Used by login/settings playlist validation.

### `src/scripts/lib/stream-diagnostic.js`

Low-level stream diagnostics for HLS/direct stream URLs. Parses HLS playlists,
checks URLs, returns report and human summary.

### `src/scripts/lib/stream-diagnostic-dialog.js`

Dialog wrapper around stream diagnostics. Renders report, supports copy to
clipboard, and uses dialog spatial navigation.

### `src/scripts/lib/provider-error.js`

Classifies provider/network errors and renders localized provider error panels.

### `src/scripts/lib/retry.ts`

Retry/backoff helper and `HttpRetryError`. Used by catalog, account info, and
EPG fetches.

### `src/scripts/lib/i18n.ts`

Localization runtime. Loads locale dictionaries, persists active locale, caches
messages for first paint, applies DOM translations, dispatches
`xt:locale-changed`.

### `src/scripts/lib/kinds.ts`

Kind constants and labels/icons for `live`, `vod`, `series` and aggregate views.

### `src/scripts/lib/text.ts`

Text normalization and normalized-token scoring helpers for search/filtering.

### `src/scripts/lib/format.ts`

Small formatting helpers: HTML escaping, age, byte sizes, IMDb/rating display.

### `src/scripts/lib/log.ts`

Logging helpers and URL redaction. Use when logging provider URLs or credentials.

### `src/scripts/lib/toast.ts`

Toast notification system. Provides `toast`, `toastSuccess`, `toastError`,
`toastWarn`. Injects styles and manages stack/dismissal.

### `src/scripts/lib/notify.ts`

Native notification wrapper using Tauri notification plugin when available.

### `src/scripts/lib/clipboard.ts`

Clipboard wrapper using Tauri clipboard plugin fallback. Used by diagnostics and
context menus.

### `src/scripts/lib/external-link.ts`

Opens external URLs via Tauri opener when available; falls back safely. Also
binds external links in DOM.

### `src/scripts/lib/discord-rpc.js`

Frontend Discord Rich Presence bridge. Reads app settings, invokes Rust
commands, supports playlist mute/global enable rules.

### `src/scripts/lib/tray-handler.ts`

Frontend side of tray navigation/hidden-to-tray behavior. Listens to Tauri
events and syncs close-to-tray setting to backend.

### `src/scripts/lib/connectivity.ts`

Connectivity monitor. Shows reconnect toast and can trigger catalog warmup after
network returns. Dispatches reconnect event.

### `src/scripts/lib/category-picker.ts`

Reusable category picker controller. Handles active category persistence,
pseudo-categories, hidden/allowed modes, search/filter, dialog spatial
navigation, and category change event dispatch.

### `src/scripts/lib/dialog-spatial-nav.ts`

Focus/spatial navigation helpers for dialogs and popovers.

### `src/scripts/lib/keyboard-help.ts`

Keyboard/D-pad help content builder using i18n labels.

### `src/scripts/lib/focus-glide.ts`

Animated focus indicator for keyboard/TV navigation. Disabled/suppressed in
performance mode.

### `src/scripts/lib/player-focus-keeper.ts`

Keeps focus/controls sane around embedded player surfaces.

### `src/scripts/lib/pip-toggle.ts`

Picture-in-picture toggle helper for player handles.

### `src/scripts/lib/external-player-button.ts`

Reusable external-player escape-hatch button logic. Picks MPV/VLC/Android
handoff, surfaces launch errors, responds to player settings changes.

### `src/scripts/lib/player-picker-dialog.ts`

Android video player picker dialog. Uses available Android video apps and
external-link icon.

### `src/scripts/lib/entry-card.ts`

Reusable poster/card builder for VOD/series entries. Integrates favorite and
watchlist UI, rating, poster fallback, and context menu hooks.

### `src/scripts/lib/poster-menu.ts`

Context menu for movie/series posters. Offers open/detail, favorites/watchlist,
download, copy stream URL, and uses preferences/clipboard/toast.

### `src/scripts/lib/morph-detail.ts`

Detail-page visual helpers: ambient background, poster fallback, poster paint,
MIME choice.

### `src/scripts/lib/programme-dialog.js`

EPG programme detail dialog with time/date/duration formatting and spatial nav.
Shows a live watch CTA for current programmes and a recording/replay CTA for
ended programmes when `canReplay` is provided. Replay navigation passes
`catchupStart` and `catchupStop` to `/livetv`.

### `src/scripts/lib/confirm-dialog.ts`

Reusable confirm dialog with i18n and spatial navigation.

### `src/scripts/lib/sort-menu.ts`

Runtime behavior for sort menu controls.

### `src/scripts/lib/b64-utf8.ts`

Base64-to-UTF8 helper and HTML escaping. Used for encoded stream metadata.

### `src/scripts/lib/debounce.ts`

Debounce helper used by search/filter/UI scripts.

### `src/scripts/lib/icons.ts`

Shared inline icon SVG constants for places not using Svelte Tabler icons.

### `src/scripts/lib/changelog.ts`

Fetches GitHub releases and renders release markdown via `marked` and
`dompurify`.

### `src/scripts/lib/backup.js`

Settings backup import/export. Snapshots credentials, preferences, and app
settings. Validates format name/version and acceptable paths.

### `src/scripts/lib/splash-backdrop.ts`

Splash background effect setup/teardown.

### `src/scripts/lib/splash-comet.ts`

Splash comet effect setup/teardown; parses accent color.

## Native Tauri files

### `src-tauri/src/main.rs`

Tauri binary entry point. Calls `app_lib::run()`.

### `src-tauri/src/lib.rs`

Tauri app builder. Registers plugins, desktop-only updater/window-state/Discord
external-player/tray commands, Android FS plugin, logging in debug, custom
window chrome behavior, and runs generated context.

### `src-tauri/src/external_player.rs`

Rust bridge for external player detect/exists/launch. Validates path/args,
spawns MPV/VLC, classifies errors, manages reuse slots, MPV JSON IPC, VLC
one-instance mode, pid liveness, stale socket cleanup, and unit tests.

### `src-tauri/src/discord.rs`

Discord Rich Presence Rust bridge. Lazily connects IPC client per app ID,
sets/clears/disconnects activity, supports assets, timestamps, and buttons.

### `src-tauri/src/tray.rs`

Desktop tray and close-to-tray behavior. Creates tray menu, toggles window,
emits `xt:tray:navigate`, intercepts close requests when enabled.

### `src-tauri/build.rs`

Tauri build script.

### `src-tauri/Cargo.toml`

Rust package/dependencies. Desktop dependencies include updater, Discord, and
window-state; Android dependencies include Android FS plugin/logger/ctor.

### `src-tauri/tauri.conf.json`

Tauri app configuration, bundle identity, windows, icons, security, updater,
and platform configuration.

### `src-tauri/capabilities/default.json`

Default Tauri permissions. Update deliberately when adding plugin access.

### `src-tauri/capabilities/desktop.json`

Desktop capability permissions for app window/plugins/commands.

### `src-tauri/capabilities/android.json`

Android capability permissions.

## Android generated/native bridge files

### `src-tauri/gen/android/app/src/main/java/com/lelegiptv/player/MainActivity.kt`

Android WebView bridge activity. Exposes JavaScript interfaces for Android
intent playback, device info/status bar, and platform-specific behavior used by
frontend modules. Read before changing Android handoff or filesystem behavior.

### `src-tauri/gen/android/app/src/main/AndroidManifest.xml`

Android manifest: app activity, intent/security/platform declarations.

### `src-tauri/gen/android/app/build.gradle.kts`

Android app Gradle build config generated/managed by Tauri Android.

### `src-tauri/gen/android/build.gradle.kts`

Top-level Android Gradle build config.

### `src-tauri/gen/android/settings.gradle`

Android Gradle settings.

### `src-tauri/gen/android/buildSrc/src/main/java/com/lelegiptv/player/kotlin/BuildTask.kt`

Generated build helper for Android/Tauri build tasks.

### `src-tauri/gen/android/buildSrc/src/main/java/com/lelegiptv/player/kotlin/RustPlugin.kt`

Generated Gradle plugin glue for Rust/Tauri Android build integration.

### `src-tauri/gen/android/app/src/main/res/xml/file_paths.xml`

Android file provider paths.

### `src-tauri/gen/android/app/src/main/res/xml/network_security_config.xml`

Android network security config. Important for HTTP IPTV providers.

### Android resource files

Files under `src-tauri/gen/android/app/src/main/res/values*`,
`drawable*`, and `layout` are generated/native Android resources for colors,
themes, strings, launcher/splash assets, and activity layout. Treat as platform
resources, not primary frontend UI.

## Docs site files

### `docs/astro.config.mjs`, `docs/package.json`, `docs/tsconfig.json`

Standalone docs Astro app configuration and dependencies.

### `docs/src/layouts/DocsLayout.astro`

Docs site layout with navigation/sidebar/command palette shell.

### `docs/src/styles/global.css`

Docs site styling independent from app styling.

### `docs/src/pages/index.astro`

Docs site landing/index page.

### `docs/src/pages/getting-started.mdx`

User docs for first setup/getting started.

### `docs/src/pages/playlists.mdx`

User docs for playlist configuration.

### `docs/src/pages/external-players.mdx`

User docs for MPV/VLC/external player setup.

### `docs/src/pages/keyboard-and-d-pad.mdx`

User docs for keyboard and TV remote navigation.

### `docs/src/pages/troubleshooting.mdx`

User troubleshooting docs.

### `docs/src/pages/translations.md`

Translation/localization documentation.

### `docs/src/components/SiteNav.astro`

Docs site navigation component.

### `docs/src/components/Sidebar.astro`

Docs site sidebar component.

### `docs/src/components/CommandPalette.astro`

Docs site command palette/search navigation component.

### `docs/src/components/HubCard.astro`

Docs site card component.

### `docs/src/components/Icon.astro`

Docs site icon component.

### `docs/src/components/Callout.astro`

Docs site callout/admonition component.

## Tests and fixtures

### `tests/m3u-parser.test.ts`

Tests M3U parser behavior with fixtures: standard, alternate order,
catchup, VLC options/headers, HLS master.

### `tests/epg-data.test.ts`

Tests EPG URL resolution, parsing/merge/mapping helpers, offset behavior, and
related pure functions.

### `tests/player-runtime.test.ts`

Tests MPV/VLC argv builders, error classification, and external availability
gates.

### `tests/log.test.ts`

Tests logging/redaction helpers.

### `tests/fixtures/m3u/standard.m3u`

Baseline M3U parser fixture.

### `tests/fixtures/m3u/alt-order.m3u`

M3U parser fixture for tags/attributes in alternate order.

### `tests/fixtures/m3u/catchup.m3u`

M3U parser fixture for catchup-related attributes.

### `tests/fixtures/m3u/extvlcopt-headers.m3u`

M3U parser fixture for `#EXTVLCOPT` headers and playback metadata.

### `tests/fixtures/m3u/hls-master.m3u`

M3U parser fixture for HLS master-playlist handling.

## Data assets

### `src/i18n/en.json`

English source locale. Add new user-visible keys here first.

### `src/i18n/es.json`

Spanish locale dictionary.

### `src/i18n/de.json`

German locale dictionary.

### `src/i18n/fr.json`

French locale dictionary.

### `src/i18n/pt-BR.json`

Brazilian Portuguese locale dictionary.

### `src/i18n/it.json`

Italian locale dictionary.

### `src/i18n/ru.json`

Russian locale dictionary.

### `src/i18n/zh.json`

Chinese locale dictionary.

### `src/i18n/ja.json`

Japanese locale dictionary.

### `src/i18n/tr.json`

Turkish locale dictionary.

### `src/i18n/ar.json`

Arabic locale dictionary. RTL locale.

### `src/i18n/ur.json`

Urdu locale dictionary. RTL locale.

### `src/i18n/nl.json`

Dutch locale dictionary.

### `src/i18n/hi.json`

Hindi locale dictionary.

### `src/i18n/id.json`

Indonesian locale dictionary.

### `src/i18n/pl.json`

Polish locale dictionary.

Locale rule: add keys consistently when adding user-visible strings. Runtime
loader and first-paint cache live in `src/scripts/lib/i18n.ts` and
`src/layouts/Layout.astro`.

### `public/favicon.svg`

Web favicon asset.

### `src-tauri/icons/**`

Desktop/Android app icon assets. Binary/image assets are not behavior files.
