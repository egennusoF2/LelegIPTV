# Frontend pages and components

## Page architecture pattern

Most pages follow this pattern:

1. Astro page defines semantic DOM, IDs, buttons, empty states, dialogs, and
   Svelte islands.
2. Browser script imports shared modules and queries DOM by ID.
3. Browser script loads active playlist and cache/preferences.
4. Browser script subscribes to relevant `xt:*` events.
5. User interactions call shared modules, which persist state and dispatch
   events.

This is not a single-page app store architecture. Do not add a new global state
framework unless explicitly requested.

## Home route

Files:

- `src/pages/index.astro`
- `src/components/HubStrips.svelte`
- `src/components/ContinueWatching.svelte`
- `src/components/FavoritesStrip.svelte`
- `src/components/WatchlistStrip.svelte`
- `src/components/RecentlyAddedStrip.svelte`
- `src/components/WelcomeCard.astro`

Responsibilities:

- Detect first run/no playlist state.
- Show hub tiles and configurable strips.
- Use cached catalog and preferences to avoid expensive network at first paint.
- Refresh tile art after active playlist or catalog warmup.

Relevant modules: `creds.js`, `cache.js`, `preferences.js`, `epg-data.js`,
`app-settings.js`, `catalog.js`, `i18n.ts`.

## Live TV route

Files:

- `src/pages/livetv.astro`
- `src/scripts/stream/stream.ts`
- `src/components/CategoryPickerDialog.astro`
- `src/components/SearchInput.astro`

Responsibilities:

- Live channel virtual list.
- Category/search filtering.
- Embedded or external playback.
- HLS/DASH/MPEG-TS/native embedded playback selection.
- Xtream HLS startup retry as MPEG-TS when a live `.m3u8` stalls.
- Channel context menu and diagnostics.
- Radio/audio-only display.
- EPG side panel.
- Recorded/catchup programme playback via `catchupStart`/`catchupStop`.
- Numeric D-pad channel selection.
- Favorites and recents.

Important DOM IDs include `list`, `viewport`, `spacer`, `player`, `player-wrap`,
`current`, `epg-list`, `category-picker-trigger`, `search`, `list-status`.

High-risk areas:

- Virtual list row height and focus behavior.
- Player teardown/remount when backend or active channel changes.
- Stream URL headers and mirror fallback.
- Container detection and teardown for HLS/DASH/MPEG-TS handles.
- Replay URLs must not be treated as normal live recents if that would confuse
  user history.
- TV remote navigation and performance mode.

## Movies route

Files:

- `src/pages/movies/index.astro`
- `src/scripts/movies/movies.ts`
- `src/pages/movies/detail.astro`
- `src/scripts/movies/detail.ts`

Listing responsibilities:

- Fetch/cache VOD catalog.
- Fetch category names.
- Search, sort, category picker.
- Favorites/watchlist/recents pseudo states.
- Infinite poster grid and skeletons.
- Context menu.

Detail responsibilities:

- Fetch/cache VOD info.
- Paint poster, ambient visual, metadata, trailer link.
- Start embedded or external playback.
- Track progress/resume/completed.
- Start downloads.
- Update favorite/watchlist.

High-risk areas:

- M3U playlists do not support VOD API.
- Provider result shape varies.
- Progress retention and completed threshold live in preferences.

## Series route

Files:

- `src/pages/series/index.astro`
- `src/scripts/series/series.ts`
- `src/pages/series/detail.astro`
- `src/scripts/series/detail.ts`

Listing responsibilities:

- Fetch/cache series catalog.
- Search, sort, category picker.
- Favorites/watchlist/recents.
- Render progress badges from episode progress.

Detail responsibilities:

- Fetch/cache `get_series_info`.
- Normalize episodes by season.
- Autoplay selected/resume episode.
- Track episode progress with series metadata.
- Download episode.
- Update Discord/player state.

High-risk areas:

- Providers return episodes as object by season or flat arrays.
- Episode IDs and season numbers can be inconsistent.
- Progress event detail must include enough metadata to refresh listing badges.

## EPG route

Files:

- `src/pages/epg.astro`
- `src/scripts/epg/epg.ts`
- `src/scripts/epg/mapping.ts`
- `src/scripts/lib/programme-dialog.js`

Responsibilities:

- Load live channels and XMLTV programmes.
- Fall back to Xtream per-channel EPG when full XMLTV cannot be loaded.
- Render timeline grid with fixed row/hour dimensions.
- Search/filter channels and pseudo categories.
- Open programme detail dialog.
- Mark replayable ended programmes with `REC` and open replay CTA.
- Refresh EPG and scroll to now.
- Map channels manually to EPG tvg IDs.

Important constants:

- `PX_PER_HOUR = 200`
- `HOURS_VISIBLE = 6`
- `ROW_HEIGHT = 64`
- `CHANNEL_COL_WIDTH = 240`
- `MAX_CHANNELS = 150`

High-risk areas:

- Large EPG documents can be expensive; keep worker/cache path.
- `effectiveTvgId()` can use override, direct tvg-id, or name match.
- When per-channel EPG fallback is active, programme keys are `stream:<id>`
  rather than `tvg-id`; do not accidentally filter them out.
- `/livetv` side panel and `/epg` full grid use different EPG provider paths.
- Manual mapping affects both `/epg` and `/livetv`.

## Settings route

Files:

- `src/pages/settings.astro`
- `src/scripts/settings/settings_effects.ts`
- `src/components/HiddenCategoriesEditor.svelte`
- `src/components/LocalePicker.svelte`
- `src/components/FavoritesReorder.svelte`
- `src/components/HubStripsEditor.svelte`
- `src/components/PlayerPicker.svelte`
- `src/components/TvOverscanCard.svelte`
- `src/components/CloseToTrayCard.svelte`
- `src/components/ConnectionLimitBanner.svelte`

Responsibilities:

- Playlist CRUD and diagnostics.
- Cache refresh and health display.
- EPG URL/timezone/category settings.
- App theme/display/performance settings.
- Locale settings.
- Download folder/concurrency settings.
- Backup import/export.
- External player configuration.
- Updater/changelog.
- Discord Rich Presence configuration.

High-risk areas:

- Many settings have first-paint effects in `Layout.astro`.
- Native APIs must be guarded for web/Android.
- Playlist edits must invalidate cache and notify active listeners.

## Downloads route

Files:

- `src/pages/downloads.astro`
- `src/scripts/lib/downloads.js`
- `src/scripts/lib/android-fs.js`

Responsibilities:

- List download queue.
- Pause/resume/cancel/remove.
- Show progress, speed, status, local path/URI.
- Scan/prune folder.
- Open/play local content if available.

Events:

- `xt:downloads-changed`
- `xt:download-progress`
- `xt:throughput-tick`

## Cross-playlist views

Files:

- `src/pages/favorites.astro`
- `src/components/AllFavoritesView.svelte`
- `src/pages/watchlist.astro`
- `src/components/AllWatchlistView.svelte`
- `src/pages/recently-added.astro`
- `src/components/RecentlyAddedView.svelte`
- `src/pages/search.astro`
- `src/components/SearchView.svelte`

Responsibilities:

- Aggregate active/cross-playlist content from preferences and cache.
- Hydrate cache entries before rendering.
- Switch active playlist when opening an item from another playlist.
- Use kind labels/icons from `kinds.ts`.

High-risk areas:

- Cross-playlist item metadata may be stale or missing when source playlist is
  not active.
- Links must activate correct playlist before navigation where required.

## Reusable components

`SearchInput.astro`: markup-only search input with clear affordance.

`SortMenu.astro`: sort control markup for VOD/series.

`CategoryPickerDialog.astro`: shared dialog shell for category picker runtime.

`Sidebar.astro`: app navigation and playlist switcher host.

`TitleBar.astro`: custom desktop chrome.

`WindowResizeEdges.astro`: desktop resize affordance.

`CatalogWarmingIndicator.svelte`: catalog progress global overlay.

`ConnectionLimitBanner.svelte`: account connection warning.

`WelcomeCard.astro`: first-run/empty state.

## i18n UI rules

Use:

- `data-i18n` for text content.
- `data-i18n-html` only for trusted localized HTML.
- `data-i18n-attr` for `aria-label`, `title`, and other attributes.
- `t(key, params)` for dynamic text in scripts/Svelte.

When adding text:

1. Add English key in `src/i18n/en.json`.
2. Add or mirror keys in other locale JSON files.
3. Ensure first-paint strings on global layout still use cached locale messages.
