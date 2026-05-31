# AI agent guide

This guide is for AI assistants and maintainers who need to work safely on
Extreme InfiniTV without rediscovering the codebase from scratch.

## Project shape

Extreme InfiniTV is a cross-platform IPTV player for Xtream Codes and M3U/M3U8
playlists. The primary app is an Astro site enhanced with Svelte islands and
browser-side TypeScript/JavaScript modules. Native desktop and Android shells
are provided by Tauri 2.

The app supports live TV, EPG/XMLTV schedules, VOD movies, series, offline-ish
catalog caching, favorites, watchlist, external players, TV remote navigation,
multiple playlists, and localized UI.

Release target notes:

- Desktop: Tauri builds for Windows, macOS, and Linux.
- Android/Android TV/Chromebook/Android XR: Tauri Android plus responsive and
  D-pad focused UI paths.
- iOS/iPadOS: Tauri mobile command path is wired via `tauri:ios:*`; generated
  Xcode files appear under `src-tauri/gen/ios` only after `pnpm tauri:ios:init`.
- Samsung Tizen TV: static web package path via `pnpm build` then
  `pnpm tizen:prepare`; final signing/packaging uses Tizen Studio/CLI.

## Stack

- Package manager: `pnpm@10.31.0`, pinned in `package.json`.
- Frontend: Astro 6, Svelte 5, Tailwind CSS 4 through Vite.
- Native shell: Tauri 2, Rust 2021.
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
pnpm tauri dev
pnpm tauri:android
pnpm tauri:ios:init
pnpm tauri:ios:dev
pnpm tauri:ios:build
pnpm tizen:prepare
pnpm sync:upstream -- --check
```

## Fork alignment

Before making changes, run:

```bash
pnpm sync:upstream -- --check
```

If `upstream` is missing:

```bash
pnpm sync:upstream -- --setup-upstream --check
```

For routine updates of a clean `main` branch:

```bash
pnpm sync:upstream -- --apply
```

See `docs/SYNC_UPSTREAM.md` for the full workflow and safety rules.

## Directory map

- `src/pages/`: Astro routes for the app UI.
- `src/layouts/Layout.astro`: global shell, first-paint settings, sidebar/titlebar wiring, safe-area and platform attributes.
- `src/components/`: Astro and Svelte UI components.
- `src/scripts/lib/`: shared application logic, storage, provider access, playback, cache, diagnostics, i18n, and UI helpers.
- `src/scripts/livetv|movies|series|epg|settings/`: page-level behavior modules.
- `src/styles/global.css`: Tailwind entry and global design tokens/styles.
- `src/i18n/*.json`: locale dictionaries.
- `src-tauri/`: Rust/Tauri host, capabilities, Android project, icons, native commands.
- `packaging/tizen/`: Samsung Tizen TV Web App metadata and packaging notes.
- `scripts/prepare-tizen.mjs`: copies `dist/` into a Tizen-ready project root.
- `tests/`: Vitest coverage for pure functions and data parsers.
- `docs/src/`: documentation website pages and components.
- `scripts/`: repository maintenance scripts, currently upstream sync.

## Routing and UI model

Astro pages render the static DOM and include page scripts. Interactive pieces
are either Svelte islands or browser modules imported from `src/scripts`.

Key routes:

- `/`: hub/home experience.
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

`src/scripts/lib/player-runtime.ts` is the unified playback mount and launch
surface.

Supported backends:

- Embedded: Video.js and Artplayer.
- Desktop external: MPV and VLC through Tauri command `launch_external_player`.
- Android handoff: system intent or VLC package when available.

Embedded playback supports HLS (`.m3u8`), MPEG-TS (`.ts` through `mpegts.js`),
DASH (`.mpd` through `dashjs`), and native browser media formats. URL extension
and MIME hint are checked first; otherwise a small content-type probe chooses
the container. Live Xtream startup has an HLS-to-TS retry path for providers or
devices where the `.m3u8` variant stalls.

Keep argument construction pure and testable. Existing tests cover MPV/VLC
argv builders and error classification. Add tests for new backend behavior
instead of relying only on manual playback.

Stream URL construction lives in `src/scripts/lib/stream-urls.ts` and related
helpers such as `stream-headers.ts`. Mirror-aware stream probing is in
`xtream-api.js`.

## Persistence and events

Tauri builds persist credentials and preferences via
`@tauri-apps/plugin-store`, mirrored to `localStorage`/cookies. Web builds use
`localStorage`/cookies directly.

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

## Native host

`src-tauri/src/lib.rs` builds the Tauri app and registers plugins. Desktop-only
modules are behind platform cfg gates:

- `discord.rs`: Discord Rich Presence commands/state.
- `external_player.rs`: MPV/VLC process launch and reuse behavior.
- `tray.rs`: desktop tray and close-to-tray behavior.

Android has generated Gradle/Kotlin files under `src-tauri/gen/android/`.
`MainActivity.kt` exposes Android bridges used by browser-side code for intents,
status bar/device information, and Android-specific behavior.

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
pnpm tauri dev
pnpm tauri:android
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

1. Run `pnpm sync:upstream -- --check`.
2. Run `git status --short` and preserve user changes.
3. Read the target route in `src/pages/`.
4. Read the page script or component it loads.
5. Identify the owning library module in `src/scripts/lib/`.
6. Add or adjust focused tests when changing pure behavior.
7. Run `pnpm test`, then `pnpm lint` or `pnpm build` when the change reaches UI
   or bundling.
