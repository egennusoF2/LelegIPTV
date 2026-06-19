# Project brief for AI agents

## Product

Leleg IPTV is a cross-platform IPTV player for Xtream Codes and M3U/M3U8
playlists. It supports Live TV, EPG/XMLTV, VOD movies, series, favorites,
watchlist, Continue Watching, recently added, offline downloads, external
players, Discord Rich Presence, TV remote navigation, multiple playlists, and
localized UI.

## Stack

- Frontend shell: Astro routes in `src/pages`.
- Interactive UI: Svelte islands in `src/components` plus browser modules in
  `src/scripts`.
- Styling: Tailwind CSS 4 via Vite, global design tokens in
  `src/styles/global.css`.
- Native app: Flutter under `native/flutter/leleg_iptv`, with platform bridges
  for downloads, playback, storage, iOS background transfers, Android
  DownloadManager, macOS media playback, and Tizen AVPlay.
- Legacy shell: Tauri 2 in `src-tauri` remains in the repository for historical
  context and web-era code, but it is not the active native release path.
- Package manager: `pnpm@10.31.0`.
- Tests: Vitest under `tests`.
- Docs site: a separate Astro app under `docs`.

## Runtime model

Astro renders stable route DOM. Page scripts query DOM nodes by ID and mount
behavior. Most persistent and cross-route state is not centralized in a SPA
store; it lives in browser modules under `src/scripts/lib` and communicates via
DOM `CustomEvent`s such as `xt:active-changed`, `xt:entries-updated`,
`xt:favorites-changed`, `xt:catalog-warmed`, and `xt:epg-loaded`.

The app must work in several environments:

- Web preview: no native plugins, localStorage/cookie persistence only.
- Flutter macOS/iOS/iPadOS: native media playback through `media_kit` where
  available and Apple platform bridges for downloads and orientation behavior.
- Flutter Android phone/tablet/TV: native Android app with responsive mobile,
  tablet, and TV layouts, Android DownloadManager, and D-pad/touch navigation.
- Flutter Tizen TV: `.tpk` app using Samsung AVPlay via `video_player_avplay`;
  it intentionally skips `media_kit`/`libmpv`.
- Astro SSR/build/test contexts: browser globals may be unavailable.

Release/device targets currently implied by the codebase:

- Web/PWA-style preview in modern browsers, useful for development and hosted
  static builds but without native Tauri privileges.
- Flutter desktop apps for macOS now, with Windows and Linux artifacts produced
  by CI or native host toolchains.
- Flutter Android apps for phones, tablets, and Android TV. The same APK adapts
  UI by form factor: smartphone flow, tablet/desktop flow, and TV remote flow.
- Android TV / Google TV layouts are explicitly supported by D-pad navigation,
  overscan controls, TV performance mode, and screenshot profiles.
- Chromebook is supported through Android/Flutter packaging assumptions
  and responsive layout profiles.
- Android XR is represented by screenshot profiles and should be treated as a
  large-screen Android target.
- iOS/iPhone and iPadOS are Flutter targets. Unsigned IPA packaging is handled
  by `scripts/package-flutter-ios-unsigned-ipa.sh` for Scarlet/Sideloadly/
  AltStore/Xcode sideloading.
- Samsung Tizen TV is wired through the Flutter native app, not the Astro web
  package. Build a `.tpk` with `pnpm flutter:tizen:build`; the Tizen runtime
  uses Samsung AVPlay via `video_player_avplay` and intentionally skips
  `media_kit`/`libmpv`.

## Core data ownership

- Playlists and active source: `src/scripts/lib/creds.js`.
- Catalog lists and warming: `src/scripts/lib/catalog.js`.
- IndexedDB catalog cache: `src/scripts/lib/cache.js`.
- EPG/XMLTV resolution, parsing, cache: `src/scripts/lib/epg-data.js`.
- Favorites, watchlist, recents, playback progress, category filters:
  `src/scripts/lib/preferences.js`.
- App settings: `src/scripts/lib/app-settings.js`.
- Provider network fetch abstraction: `src/scripts/lib/provider-fetch.js`.
- Playback backend abstraction: `src/scripts/lib/player-runtime.ts`.
- Stream URL construction: `src/scripts/lib/stream-urls.ts`.
- Downloads: `src/scripts/lib/downloads.js`.

## Provider modes

Xtream playlist:

- Stored as `type: "xtream"` in `creds.js`.
- Uses `serverUrl`, `username`, `password`, optional `mirrors`, and
  `liveContainer`.
- API requests go through `xtreamApiFetch()` to `player_api.php`.
- Live, VOD, series, user info, and XMLTV are available.

Remote M3U playlist:

- Stored as `type: "m3u"` with `url`.
- Live channels are parsed from M3U text.
- VOD/series Xtream APIs are unavailable.
- EPG source may come from `x-tvg-url` header or user overrides.

Local M3U playlist:

- Stored as `type: "local-m3u"` with `sourceName`.
- Actual playlist text is stored in IndexedDB by `local-content.js`.
- `loadCreds()` returns an `xt-local://<entryId>` sentinel.

## AI editing rules

- Preserve user changes; inspect `git status --short` before edits.
- Prefer existing helper modules rather than new state systems.
- Guard browser-only globals when code can run during build/test.
- Keep playlist-scoped data scoped by playlist ID.
- Add tests for pure behavior changes in `src/scripts/lib`.
- Use provider helpers for network calls.
- Update i18n keys when adding visible UI text.
- Test desktop and Android assumptions separately for native changes.
- Before routine work, run `git status --short` and preserve local user
  changes. This repository is now the Leleg IPTV source of truth, not a fork
  that must be kept aligned with an upstream.
