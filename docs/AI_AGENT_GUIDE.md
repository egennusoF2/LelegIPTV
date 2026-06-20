# AI agent guide

This guide is for AI assistants and maintainers who need to work safely on
Leleg IPTV without rediscovering the codebase from scratch.

## Project shape

Leleg IPTV is a cross-platform IPTV player for Xtream Codes and M3U/M3U8
playlists. The web app is an Astro site enhanced with Svelte islands and
browser-side TypeScript/JavaScript modules. Native installable app work is now
centered on the Flutter app under `native/flutter/leleg_iptv`.

The app supports live TV, EPG/XMLTV schedules, VOD movies, series, offline-ish
catalog caching, favorites, watchlist, external players, TV remote navigation,
multiple playlists, and localized UI.

Release target notes:

- macOS, iOS/iPadOS, Android phone/tablet/TV, Windows, Linux, and Tizen are
  driven by the Flutter app in `native/flutter/leleg_iptv`.
- Samsung Tizen TV builds a Flutter `.tpk` via `pnpm flutter:tizen:build`;
  playback uses Samsung AVPlay through `video_player_avplay`, not `media_kit`.
- Tauri files under `src-tauri` are legacy context from the previous native
  approach. Do not use them for new native release work unless explicitly
  asked to maintain the old shell.

Important playback reset:

- The web release is the current stable playback baseline.
- Do not assume the browser/WebView playback stack can make macOS, iOS,
  Android, Android TV, and Tizen reliable.
- Future native release work must start from
  `docs/ai-rag/08-native-playback-rebuild-strategy.md`.
- The recommended direction is a shared UI plus replaceable playback backends:
  web backend for browsers, native/player-engine backend for apps, and external
  player only as fallback.
- Avoid adding more one-off VOD/container workarounds before defining or using
  the shared playback contract.

## Stack

- Package manager: `pnpm@10.31.0`, pinned in `package.json`.
- Frontend: Astro 6, Svelte 5, Tailwind CSS 4 through Vite.
- Native app: Flutter in `native/flutter/leleg_iptv`.
- Legacy shell: Tauri 2/Rust under `src-tauri`, kept for historical context.
- Tests: Vitest for pure browser/runtime utilities.
- Lint: ESLint flat config, no Prettier config.
- Docs site: separate Astro app under `docs/`.

Important commands:

```bash
pnpm install
pnpm dev
pnpm build
pnpm test
pnpm lint
cd native/flutter/leleg_iptv && flutter analyze
pnpm flutter:tizen:build
pnpm download-center:prepare
```

## Repository baseline

Before making changes, inspect the local tree and preserve user work:

```bash
git status --short
```

The app is no longer maintained as a fork that must be aligned with an
upstream project. Treat this repository as the source of truth for Leleg IPTV.
The current native app lives under `native/flutter/leleg_iptv`; Tauri files are
legacy context unless a task explicitly targets the old web/Tauri shell.

Useful current checks:

```bash
pnpm test
pnpm build:pages
cd native/flutter/leleg_iptv && flutter analyze
```

## Directory map

- `src/pages/`: Astro routes for the app UI.
- `src/layouts/Layout.astro`: global shell, first-paint settings, sidebar/titlebar wiring, safe-area and platform attributes.
- `src/components/`: Astro and Svelte UI components.
- `src/scripts/lib/`: shared application logic, storage, provider access, playback, cache, diagnostics, i18n, and UI helpers.
- `src/scripts/livetv|movies|series|epg|settings/`: page-level behavior modules.
- `src/styles/global.css`: Tailwind entry and global design tokens/styles.
- `src/i18n/*.json`: locale dictionaries.
- `src-tauri/`: legacy Rust/Tauri host retained for historical reference and
  old web-shell code paths.
- `native/flutter/leleg_iptv/`: current native app for macOS, iOS/iPadOS,
  Android, Android TV, Tizen, Windows, and Linux.
- `native/flutter/local_plugins/`: local Flutter platform plugins used by the
  native player/download integrations.
- `packaging/tizen/`: Samsung Tizen TV metadata and packaging notes.
- `tests/`: Vitest coverage for pure functions and data parsers.
- `docs/src/`: documentation website pages and components.
- `scripts/`: repository maintenance scripts for Flutter packaging, web
  download-center preparation, local dev cleanup, and log helpers.

## Routing and UI model

Astro pages render the static DOM and include page scripts. Interactive pieces
are either Svelte islands or browser modules imported from `src/scripts`.

Key routes:

- `/`: public download center in hosted builds.
- `/home`: hub/home experience for the web app.
- `/livetv`: live channel list, embedded/external player, compact EPG panel.
- `/epg`: full XMLTV schedule grid.
- `/movies` and `/movies/detail`: VOD browsing and detail/playback.
- `/series` and `/series/detail`: series browsing and episode playback.
- `/favorites`, `/watchlist`, `/recently-added`, `/search`: cross-playlist views.
- `/settings`: playlist, display, network, player, backup, and platform settings.
- `/downloads`, `/docs`, `/login`: auxiliary app flows.

The layout uses CSS variables and `data-*` attributes applied before first
paint to avoid flicker for theme, locale direction, font scale, Android/desktop
platform modes, TV performance mode, and overscan.

## Data sources

Two provider modes share most UI:

- Xtream Codes entries store `serverUrl`, `username`, `password`, optional
  mirrors, live container (`m3u8` or `ts`), and EPG overrides.
- M3U entries store a remote URL or local M3U source plus optional EPG URLs.

`src/scripts/lib/creds.js` owns playlist storage, migration from legacy flat
keys, active playlist selection, Xtream URL builders, M3U detection, mirror
metadata, and local-M3U helpers.

`src/scripts/lib/xtream-api.js` wraps Xtream `player_api.php` requests. It
tries the active playlist primary credentials first, falls back to mirrors, and
pins the working mirror in memory until entries change.

`src/scripts/lib/provider-fetch.js` is the central place for provider network
requests. Prefer using it instead of raw `fetch` when talking to IPTV providers,
because platform/proxy behavior is concentrated there.

## Catalog layer

`src/scripts/lib/catalog.js` is the shared catalog fetch/parse/cache layer.

Primary exports:

- `ensureLive(creds, playlistId, opts)`
- `ensureVod(creds, playlistId, opts)`
- `ensureSeries(creds, playlistId, opts)`

For Xtream it calls category and stream APIs, normalizes records, and sorts for
display. For M3U live TV it parses playlist text through
`src/scripts/lib/m3u-parser.ts`. Catalog calls use retry/backoff and emit
warming events such as `xt:catalog-warming-start`, `xt:catalog-warming-progress`,
`xt:catalog-warming-bytes`, and `xt:catalog-warmed`.

`src/scripts/lib/cache.js` provides an IndexedDB-backed cache with an in-memory
hydration layer. Cache keys are playlist-scoped and kind-scoped. Old entries are
pruned lazily.

## EPG layer

`src/scripts/lib/epg-data.js` owns XMLTV source resolution, fetch, parse, merge,
cache, and timezone offset behavior.

EPG source precedence:

1. User-supplied primary override.
2. Auto-detected provider source: Xtream `xmltv.php` or M3U `x-tvg-url`.
3. Additional EPG URLs, waterfall-merged to fill missing `tvg-id`s only.

Parsing uses `epg-worker.ts` when workers are available, with fallback to
main-thread parsing. Important events include `xt:epg-loaded`,
`xt:epg-offset-changed`, and `xt:epg-source-status`.

Some providers return XMLTV with `DOCTYPE` or internal `ENTITY` declarations.
The parser sanitizes those declarations before `DOMParser` instead of rejecting
the whole feed; unknown entity references are neutralized while standard XML
entities remain intact. If EPG fails with a 200 XMLTV response, check parser
sanitization before blaming provider availability.

`/livetv` and `/epg` do not use exactly the same provider path. The Live TV
side panel can use Xtream `get_short_epg` for the selected channel, while the
full `/epg` grid first tries the larger XMLTV source (`xmltv.php` or configured
EPG URLs). If the full XMLTV refresh fails, `epg-data.js` now falls back to any
parsed EPG already cached, and `src/scripts/epg/epg.ts` can build a limited grid
from Xtream per-channel EPG endpoints (`get_short_epg`, then
`get_simple_data_table`). Do not diagnose a `/epg` error as provider downtime
without checking this difference.

Catchup/replay metadata is carried in live channel records:

- Xtream: `tv_archive` and `tv_archive_duration` become `catchup: "xtream"`
  and `catchupDays`.
- M3U: `catchup`, `catchup-days`, `timeshift-days`, and `catchup-source` are
  parsed by `m3u-parser.ts`.

`src/scripts/lib/catchup.ts` decides whether an ended programme is replayable
and builds either Xtream `/timeshift/...` URLs or M3U catchup-source/append
URLs. The programme dialog receives `canReplay` and navigates to
`/livetv?channel=<id>&catchupStart=<ms>&catchupStop=<ms>` for recorded playback.

## Playback

For the current native app, playback is implemented in Flutter under
`native/flutter/leleg_iptv/lib/core/playback/**` and platform-specific files in
`android/`, `ios/`, `macos/`, and `tizen/`. Movies, series, and live TV must
share the same playlist/cache/progress model and expose the same audio,
subtitle, speed, fullscreen, and download behavior across device families.

For the web app, `src/scripts/lib/playback-session.ts` remains the playback
entry point for pages and wraps the stable web runtime through
`WebPlaybackSession`. `src/scripts/lib/player-runtime.ts` is the lower-level
web runtime. Do not add new page-level playback conditionals there unless the
same behavior is exposed through the shared playback contract.

Supported backends:

- Web embedded playback: Video.js, Artplayer, HLS/DASH helpers.
- Flutter desktop/mobile/tablet playback: `media_kit`/native platform player
  path in the Flutter app.
- Tizen TV playback: Samsung AVPlay through `video_player_avplay`.

Legacy Tauri desktop also exposes `native_playback_status` from
`src-tauri/src/native_playback.rs`. Treat it as historical context only unless
the task explicitly targets the old shell.

The playback factory emits `xt:playback-session-mounted` with capability fields
such as `nativeIntegratedPlayback`, `availableNativeBackends`, and
`recommendedNativeBackend`.

`PlaybackSession` also exposes normalized track state (`getTracks()`), track
selection (`selectAudioTrack`, `selectSubtitleTrack`), `getState()`, and
standard event subscription via `on(...)`. Native backends must implement those
operations instead of creating separate player menus or page-specific state.

Embedded playback supports HLS (`.m3u8`), MPEG-TS (`.ts` through `mpegts.js`),
DASH (`.mpd` through `dashjs`), and native browser media formats. URL extension
and MIME hint are checked first; otherwise a small content-type probe chooses
the container. Live Xtream startup has an HLS-to-TS retry path for providers or
devices where the `.m3u8` variant stalls.

Keep URL and playback-state construction pure and testable. Add tests for new
backend behavior instead of relying only on manual playback.

Stream URL construction lives in `src/scripts/lib/stream-urls.ts` and related
helpers such as `stream-headers.ts`. Mirror-aware stream probing is in
`xtream-api.js`.

## Persistence and events

Flutter builds persist credentials, playlist cache, favorites, progress,
downloads, and settings through the Flutter storage layer. Web builds use
`localStorage`/cookies/IndexedDB directly. Legacy Tauri code used
`@tauri-apps/plugin-store`; keep that path working only for the old web shell.

Important storage owners:

- `creds.js`: playlists and selected playlist.
- `preferences.js`: favorites, recents, progress, hidden/allowed categories,
  EPG mapping, watchlist, sort preferences.
- `app-settings.js`: global settings such as player backend, paths, user agent,
  display options, retention, close-to-tray, and similar app-wide toggles.
- `cache.js`: catalog and parsed data cache in IndexedDB.

Important DOM events:

- `xt:active-changed`
- `xt:entries-updated`
- `xt:favorites-changed`
- `xt:recents-changed`
- `xt:progress-changed`
- `xt:hidden-categories-changed`
- `xt:allowed-categories-changed`
- `xt:category-mode-changed`
- `xt:epg-sync-changed`
- `xt:channel-epg-changed`
- `xt:view-prefs-changed`
- `xt:watchlist-changed`
- `xt:cache-revalidated`

When adding a user-facing state mutation, check whether a DOM event already
exists and dispatch it consistently so open pages update without reloads.

## Legacy Tauri Host

`src-tauri/src/lib.rs` builds the legacy Tauri app and registers plugins. Do
not use this host for new native app development. Desktop-only
modules are behind platform cfg gates:

- `discord.rs`: Discord Rich Presence commands/state.
- `external_player.rs`: MPV/VLC process launch and reuse behavior.
- `tray.rs`: desktop tray and close-to-tray behavior.

Android has legacy generated Gradle/Kotlin files under `src-tauri/gen/android/`.
The active Android app is the Flutter project under `native/flutter/leleg_iptv`.

Tauri permissions are declared under `src-tauri/capabilities/`. When adding a
new plugin or command, update capabilities deliberately and test both desktop
and Android assumptions.

## Internationalization

Locale dictionaries are in `src/i18n/*.json`. Runtime helpers live in
`src/scripts/lib/i18n.ts`. UI text commonly uses:

- `data-i18n` for text content.
- `data-i18n-html` for trusted localized HTML.
- `data-i18n-attr` for attributes such as `aria-label` and `title`.

When adding visible UI text, update `en.json` first and mirror keys to other
locale files if possible. Avoid hard-coded strings in dynamic components unless
they are developer-only diagnostics.

## Testing strategy

Prefer tests for pure modules in `src/scripts/lib/`:

- M3U parsing: `tests/m3u-parser.test.ts`
- EPG source/merge behavior: `tests/epg-data.test.ts`
- Player backend arg/error logic: `tests/player-runtime.test.ts`
- Logging and diagnostics helpers: existing targeted tests

Run:

```bash
pnpm test
pnpm lint
pnpm build
```

For Tauri or Android changes, also run the relevant native command when the
environment supports it:

```bash
pnpm flutter:analyze
pnpm flutter:android:build
pnpm flutter:ios:build
pnpm flutter:tizen:build
```

## Change guidelines for AI agents

- Read nearby files before editing; this codebase relies on shared browser
  modules more than framework-level state management.
- Keep provider network calls behind existing helpers (`provider-fetch`,
  `xtream-api`, `retry`) unless there is a strong reason.
- Do not introduce a second persistence path for playlists, preferences, or
  settings. Extend the owning module instead.
- Preserve playlist-scoped data boundaries. Favorites, progress, categories,
  EPG mappings, and cache entries should not leak across playlist IDs unless a
  cross-playlist view explicitly aggregates them.
- Be careful with platform detection. Tauri desktop, Tauri Android, web preview,
  and SSR/build-time code paths all exist.
- Guard browser-only globals (`window`, `document`, `localStorage`, `indexedDB`,
  `Worker`, `navigator`) when code can run during Astro build or tests.
- Favor pure helper functions for parsing, URL construction, argv construction,
  and data merging; add Vitest coverage for those helpers.
- Keep accessibility attributes and TV/D-pad navigation behavior intact when
  touching UI. Focus rings and spatial navigation are first-class features.
- When adding settings, update storage, initial first-paint application if
  needed, UI controls, events, and tests together.
- When changing stream playback, verify embedded player behavior and external
  player handoff separately.

## Common risk areas

- Provider responses are inconsistent; parsers should accept arrays and common
  wrapper shapes.
- M3U and Xtream share UI but not all features. VOD/series require Xtream-style
  credentials.
- EPG data can be large; avoid main-thread work when worker/cache helpers exist.
- Android may lack desktop Tauri plugins and external process launching.
- Web preview lacks native persistence, updater, tray, and external player
  process commands.
- Locale and theme are applied before first paint in `Layout.astro`; moving this
  late can cause visible flicker.
- Cache invalidation and active playlist events are easy to miss. Search for
  existing `xt:*` events before inventing new ones.

## Quick orientation checklist

1. Run `git status --short` and preserve user changes.
2. Read the target route in `src/pages/` or Flutter screen in
   `native/flutter/leleg_iptv/lib`.
3. Read the page script, component, or native bridge it loads.
4. Identify the owning library module in `src/scripts/lib` or Flutter service.
5. Add or adjust focused tests when changing pure behavior.
6. Run `pnpm test`, then `pnpm lint` or `pnpm build` when the change reaches UI
   or bundling.
