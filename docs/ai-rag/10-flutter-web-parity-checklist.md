# Flutter Native Web-Parity Checklist

This file tracks how close the Flutter native app is to the Astro/Svelte web
app. Use it as RAG context before changing `native/flutter/leleg_iptv`.

## Current Rule

The web app remains the visual and functional source of truth. Native Flutter
may use a different playback technology (`media_kit`), but route structure,
catalog behavior, settings, and visual language should converge toward the web
experience.

## Parity Matrix

| Area | Web reference | Flutter native status | Notes |
| --- | --- | --- | --- |
| Sidebar navigation | `src/components/Sidebar.astro` | Partial | Main sections exist. Needs exact spacing, labels, active-state polish, and account/provider footer parity. |
| Home | `src/pages/index.astro` | Partial | Cards and recent movies exist. Needs full hub strips, continue watching, favorites/watchlist/recently-added strips, and exact web composition. |
| Global search | `src/components/SearchView.svelte` | Partial | Native search opens a combined result view. Missing EPG search, richer result metadata, cross-playlist behavior. |
| Live TV | `src/pages/livetv.astro` | Functional | Native categories, channel list, playback, hover controls, and contextual EPG work. Phone uses full-screen playback; iPad/iOS live/catchup also enters focus playback to avoid embedded small-player issues. TV/desktop keep the large embedded layout. |
| Live contextual EPG | `src/pages/livetv.astro`, `src/scripts/lib/epg-data.js` | Functional | Uses Xtream `get_short_epg` with `epg_listings` parsing and per-channel cache. Past/current/future programmes are sorted chronologically and the list auto-scrolls near the current programme while still allowing catchup selection. |
| EPG page | `src/pages/epg.astro`, `src/scripts/epg/epg.ts` | Functional | Native page has category filter, refresh, batched `get_short_epg`, XMLTV fallback from `xmltv.php`, horizontal timeline controls, dark hover details, catchup badges, and channel rows. Remaining parity gaps: mapping dialog, favorites/recents categories, and manual mapping UI. |
| Movies catalogue | `src/pages/movies/index.astro` | Partial | Categories, list/grid, play, favorites/watch later exist. Needs exact filters/sort menu, provider errors, hidden categories, and metadata density. |
| Movie detail | `src/pages/movies/detail.astro` | Partial | Native playback and basic metadata exist. Needs trailer behavior, full detail metadata, persistent resume, full favorite/watch later persistence, and exact web visual rhythm. |
| Series catalogue | `src/pages/series/index.astro` | Partial | Categories, sorting, opening series, and episode playback exist. Needs exact cards, season navigation polish, favorites/watchlist, and detail parity. |
| Favorites | `src/pages/favorites.astro`, `src/components/AllFavoritesView.svelte` | Minimal | Native currently tracks movie favorites in memory only. Needs persistent cross-kind/cross-playlist favorites, reorder, metadata backfill, and navigation parity. |
| Watch later | `src/pages/watchlist.astro`, `src/components/AllWatchlistView.svelte` | Minimal | Native currently tracks movie watch-later in memory only. Needs persistent VOD/series support and cross-playlist behavior. |
| Recently added | `src/pages/recently-added.astro` | Minimal | Native shows recent movies only. Needs all-kind filtering and web sorting semantics. |
| Downloads | `src/pages/downloads.astro` | Functional | Movie downloads route to a native queue. Android delegates to `DownloadManager`; iOS/iPadOS uses `URLSessionConfiguration.background` through `com.lelegiptv.native/storage`; desktop writes to `~/Downloads/LelegIPTV`. Remaining gap: pause/resume/cancel UI parity. |
| Settings playlists | `src/pages/settings.astro`, login flow | Functional | Native persists multiple Xtream profiles, shows saved list names, switches active list, removes lists, refreshes active list on request, clears the form after save, supports shortcut codes (`ITALIA1/2/3`, `MONDO1/2`), and caches catalog data for 24 hours. Missing import/export, M3U/local playlists, and full account metadata parity. |
| Settings appearance | `src/pages/settings.astro` | Missing | Needs language, theme, font scale, TV safe area, home strip editor, web install card equivalent where relevant, close behavior. |
| Settings watching | `src/pages/settings.astro` | Missing | Needs Live TV layout, progress retention, EPG timezone/offset, playback backend/preferences where relevant to native. |
| Settings network | `src/pages/settings.astro` | Missing | Needs network/user-agent/provider diagnostics and native-specific connection checks. |
| Settings library/data | `src/pages/settings.astro` | Missing | Needs hidden categories, favorites reorder, hub strips, downloads folder, backup/export/import, cache/storage controls. |
| Player | Web ArtPlayer/Shaka/HLS stack | Functional | Flutter uses `media_kit` where available and iOS media paths where needed; the dedicated Tizen app uses Samsung AVPlay. Play/pause/seek/audio track selector/subtitle selector/speed/fullscreen are wired. Unsupported PiP controls are intentionally hidden. On non-TV layouts, tapping the inline video enters fullscreen; fullscreen taps reveal the auto-hiding controls. |
| Icons/app identity | `src-tauri/app-icon.png` | Functional | Flutter Android/iOS/macOS/Tizen icons are generated from the Leleg icon. Dock/launcher may cache old icons until app rebuild/reinstall. |

## Native EPG Implementation Notes

- Contextual Live EPG and the EPG page both call Xtream `get_short_epg`.
- Providers commonly return programme rows under `epg_listings`; the native
  client also accepts `epg_list`, `epg`, and `programmes`.
- The general EPG page deliberately ignores the global search query. It follows
  the selected live category, then loads up to 80 channels in six-channel
  batches to avoid the page feeling frozen.
- If `get_short_epg` returns no programmes for the selected channels, native
  falls back to `xmltv.php`, parses XMLTV, resolves channels by
  `epg_channel_id`/`tvg_id`, stream id, or unique normalized display-name, and
  fills the same guide rows.
- This is not full web EPG parity yet. The web page builds a horizontal
  timeline from XMLTV/programme maps, supports channel mapping, favorites,
  recents, "Now", and catchup eligibility.

## Next Native Porting Order

1. Stabilize EPG general page visual parity: time header, timeline positioning,
   now button, channel mapping entry point.
2. Complete playlist settings: display names/rename, edit existing credentials,
   import/export, M3U/local sources, and account metadata panels.
3. Persist favorites, watch later, and continue watching by playlist and kind.
4. Complete Downloads parity: pause/resume/cancel, folder management, and persisted completed items.
5. Port remaining Settings groups in this order: appearance, watching,
   library/data, help/about.
6. Keep validating the same Flutter codebase on iPhone, iPad, Android phone,
   Android tablet/TV, macOS, Windows, Linux, and Samsung Tizen. Tablet/iPad and
   desktop share the large layout; phones use the compact fullscreen-first
   player flow; TV targets add D-pad focus semantics.

## Native Catalog Cache

- Profiles are saved under `leleg.native.profiles`; the active profile id is
  saved under `leleg.native.active_profile_id`.
- The legacy single profile key `leleg.native.profile` is migrated into the
  profile list on first launch.
- Catalog cache is per profile under `leleg.native.catalog.<profile-id>`.
- Cached payload includes live/movie/series categories and live/movie/series
  catalog entries.
- The app reuses cached catalog data when it is newer than 24 hours.
- "Ricarica dal provider" bypasses the cache and downloads the catalog again.
- Saving a profile no longer forces a provider reload by default; it reuses the
  24-hour cache when available and clears the form after the active list is
  stored.
