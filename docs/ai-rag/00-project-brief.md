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
- Native shell: Tauri 2 in `src-tauri`, Rust commands for desktop features,
  Android generated project under `src-tauri/gen/android`.
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

- Web preview: no Tauri plugins, localStorage/cookie persistence only.
- Tauri desktop: native window, tray, updater, plugin-store, filesystem,
  notifications, external process launch.
- Tauri Android: Android WebView, Android filesystem plugin, Android bridges,
  no desktop process launching.
- Tauri iOS/iPadOS: mobile WebView target through `tauri ios`; no desktop
  process launching and every native plugin call must be guarded.
- Samsung Tizen TV: static Web App package generated from `dist`; no Tauri
  plugins, no Rust commands, playback depends on TV browser media support.
- Astro SSR/build/test contexts: browser globals may be unavailable.

Release/device targets currently implied by the codebase:

- Web/PWA-style preview in modern browsers, useful for development and hosted
  static builds but without native Tauri privileges.
- Desktop Tauri apps for Windows, macOS, and Linux. Desktop supports tray,
  updater, filesystem downloads, plugin-store, notifications, Discord Rich
  Presence, and MPV/VLC process launch.
- Android Tauri apps for phones and tablets. Android uses WebView, Android
  filesystem APIs, native intent handoff, status bar/device bridges, and VLC or
  system player handoff where installed.
- Android TV / Google TV layouts are explicitly supported by D-pad navigation,
  overscan controls, TV performance mode, and screenshot profiles.
- Chromebook is supported through Android/Tauri-WebView packaging assumptions
  and responsive layout profiles.
- Android XR is represented by screenshot profiles and should be treated as a
  large-screen Android target.
- iOS/iPhone and iPadOS are wired at command level through Tauri mobile scripts:
  `pnpm tauri:ios:init`, `pnpm tauri:ios:dev`, and `pnpm tauri:ios:build`.
  The generated Xcode project is expected under `src-tauri/gen/ios` after init
  and requires macOS, Xcode, Apple signing, and device/simulator validation.
- Samsung Tizen TV is wired as a Web App packaging path:
  `pnpm build && pnpm tizen:prepare` prepares `build/tizen-web` with
  `packaging/tizen/config.xml`; final `.wgt` signing/packaging happens with
  Tizen Studio or Tizen CLI and a Samsung certificate profile.

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
- Before routine work on this fork, run `pnpm sync:upstream -- --check`.
