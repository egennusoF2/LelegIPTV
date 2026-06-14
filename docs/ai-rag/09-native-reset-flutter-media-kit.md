# Native Reset: Flutter + media_kit

This document is the current source of truth for rebuilding Leleg IPTV native
apps after the failed macOS Tauri/libmpv embedding experiment.

## Decision

Keep the current Astro/Svelte web app as the stable web/PWA release.

Rebuild native apps as a separate Flutter application using `media_kit` for
playback. The Flutter app should reuse Leleg IPTV domain knowledge, Xtream API
rules, EPG/catchup logic, and UI language, but it should not reuse the current
Tauri/WebView playback architecture.

## Why the current Tauri native playback is paused

The current Tauri/libmpv experiment proved that media decoding is not the main
problem: audio can play and native track discovery can return audio/subtitle
tracks. The failure is the UI/rendering architecture:

- native `libmpv` video is rendered below the WebView;
- the existing detail/live pages were designed around HTML `<video>`;
- WebView opacity and page layers hide or clip the native video surface;
- native controls bolted onto existing pages only partially dispatch;
- live and VOD behavior regress while web playback still works.

The experiment is now disabled by a JavaScript kill-switch in
`src/scripts/lib/playback-session.ts`:

```ts
const ENABLE_TAURI_NATIVE_PLAYBACK = false
```

Do not re-enable this flag unless a dedicated native player screen has been
implemented and tested.

## What other working projects do

### MaxVideoPlayer

MaxVideoPlayer uses Tauri plus a custom `tauri-plugin-mpv` wrapper. The native
player is not an HTML video player. It is a native `libmpv2` backend with:

- a platform renderer trait;
- macOS `NSOpenGLView` rendering;
- native state polling/events;
- UI controls implemented as web/React commands over native playback state;
- a dedicated player route/screen.

Reference:

- https://github.com/MaxMB15/MaxVideoPlayer
- local reference clone, when present: `/private/tmp/MaxVideoPlayer`

Important lesson: if staying with Tauri, clone the whole player architecture,
not only small rendering snippets.

### Another IPTV Player

Another IPTV Player says its old Flutter app is deprecated in favor of native
clients per platform, but its Flutter implementation uses `media_kit`, a mature
cross-platform playback stack.

Reference:

- https://github.com/bsogulcan/another-iptv-player
- https://github.com/media-kit/media-kit

Important lesson: a cross-platform IPTV app should delegate playback to a
native media engine that already owns rendering, track selection, subtitles,
headers, seeking, and platform GPU integration.

### Megacubo

Megacubo is Electron/Capacitor, not Tauri. It uses web playback libraries such
as `hls.js`, `mpegts.js`, and `dashjs`, but also ships native/player/ffmpeg
plugins and external-player support.

Reference:

- https://github.com/EdenwareApps/Megacubo

Important lesson: Megacubo is not simply a WebView around `<video>`. It has
player-specific native/runtime layers.

## Target platform strategy

### Web/PWA

Keep current Astro/Svelte implementation.

Playback stack:

- HLS/DASH/MPEG-TS through current web player strategy;
- Shaka/hls.js/mpegts.js where already working;
- continue validating in Chrome/Safari-like browsers.

### macOS, Windows, Linux

Preferred reset path: Flutter + `media_kit`.

Playback expectations:

- MKV, MP4, HLS, MPEG-TS via native backend;
- selectable audio tracks;
- selectable embedded subtitles;
- external subtitles later;
- resume/seek using native player state.

### Android / Android TV

Preferred reset path: same Flutter + `media_kit` app first.

If Android TV/Fire TV UX requires special remote handling, add TV-specific
focus/remote layers in Flutter, not in the web app.

### iOS / iPadOS

Use Flutter + `media_kit` if it satisfies App Store/device constraints for
target streams. If iOS codec limitations block MKV/codec coverage, create an
iOS-specific playback abstraction backed by AVPlayer where possible and a
server/proxy/transcode plan only where unavoidable.

### Tizen / Samsung TV

Tizen is not naturally covered by Flutter desktop/mobile. Treat it as a
separate web-TV target:

- keep a TV-optimized web build;
- use Samsung AVPlay for app packaging when building a real Tizen app;
- do not assume the Tauri or Flutter app can be reused directly.

## Prototype acceptance criteria

The Flutter prototype is not accepted until these checks pass against the same
real provider streams used during debugging:

1. Login with Xtream credentials.
2. Fetch live categories and streams.
3. Fetch VOD categories and streams.
4. Play one live TS/HLS stream with video and audio.
5. Play one VOD MKV stream with correct full duration.
6. Seek near the middle of the VOD.
7. List audio tracks.
8. Switch audio track without restarting from zero.
9. List subtitle tracks.
10. Enable and disable subtitles.
11. Save progress.
12. Re-open the VOD and resume.

## Implementation shape

Current prototype path:

```text
native/flutter/leleg_iptv/
```

Current prototype status:

- created with Flutter 3.44.0;
- bundle id namespace: `com.lelegiptv`;
- app name/project: `leleg_iptv`;
- dependencies installed: `media_kit`, `media_kit_video`,
  `media_kit_libs_video`, `http`, `shared_preferences`, `window_manager`;
- `lib/main.dart` is a native shell prototype, not the final UI;
- it initializes `MediaKit.ensureInitialized()`;
- it uses `Player`, `VideoController`, and `Video`;
- it exposes Xtream profile fields, account/catalog load, Live/Movies tabs,
  list search, stream URL fallback, Play, audio track menu, subtitle track menu,
  and playback speed menu;
- it stores the last tested URL in `SharedPreferences`.
- `lib/domain/xtream_client.dart` implements direct Xtream calls for
  `get_account_info`, `get_live_categories`, `get_live_streams`,
  `get_vod_categories`, `get_vod_streams`, `get_series_categories`,
  `get_series`, `get_series_info`, and stream URL construction for
  `/live/...`, `/movie/...`, and `/series/...`.
- Xtream API calls send browser/player-like headers (`Accept`, VLC-style
  `User-Agent`, provider `Referer`) and use longer per-endpoint timeouts:
  account 30s, categories 45s, live 75s, VOD/series 150s. Catalog loading is
  progressive: account, categories, live, movies, then series. A slow VOD or
  series list must not zero out already loaded live channels.
- macOS entitlements include `com.apple.security.network.client`; without it
  remote streams fail to open in the sandboxed app.
- The Flutter UI must converge toward the web app, not a separate product.
  Current shell now mirrors the web information architecture: fixed sidebar,
  brand/search/navigation, Home, Live TV, Movies, Favorites, Watch later,
  Recently added, EPG, Downloads, Settings. Live, Movies, Movie detail playback,
  the top-level Series catalogue, and the Series episode detail view are
  functional. Live, Movies, and Series expose category filters, global search,
  and basic sorting to match the web catalogue workflow. The player now uses a
  hover/mouse-move-revealed native control bar for play/pause, duration, seek,
  audio track, subtitle track, playback speed, fullscreen, and PiP status. The
  bar auto-hides after pointer inactivity to avoid covering Live TV.
  Fullscreen is wired through `window_manager` and toggles the macOS window
  plus the in-app focus player layout. PiP is still reported as unavailable
  because it requires a dedicated native macOS/iOS layer beyond `media_kit`.
  Navigation through the sidebar/home cards stops the active player so audio
  cannot keep playing after changing page. Global search now shows a dedicated
  Search results page from Home, and opening a result navigates to the correct
  Live/Movie/Series surface before playback. Catalog loading is progressive:
  category endpoints no longer block Live TV, and the Home page shows the
  current loading step.
  Live contextual EPG and the EPG page use Xtream `get_short_epg`; the client
  reads the provider key `epg_listings` used by Xtream panels and caches rows by
  channel. If `get_short_epg` returns no programmes for the EPG page, native
  falls back to `xmltv.php`, parses XMLTV, and maps channels by
  `epg_channel_id`/`tvg_id`, stream id, or unique normalized display-name. The
  contextual Live layout gives the player less vertical weight so more
  programme cards are visible below it. The EPG page renders a guide-like
  channel/programme grid for up to 80 selected-category channels, includes a
  category picker and refresh action, and loads rows in small batches to avoid a
  frozen first paint. Web-style timeline rendering, manual EPG mapping UI,
  favorites/recents EPG filters, and catchup workflow are still pending.
  Detailed web-parity status lives in `docs/ai-rag/10-flutter-web-parity-checklist.md`.
  Downloads, persistence of favorites/watch-later, richer movie/series metadata
  pages, native PiP, and full visual pixel parity are still pending.
- Native Settings now persists multiple Xtream profiles instead of a single
  profile only. The active profile is saved separately, legacy single-profile
  storage is migrated automatically, and the catalog for each profile is cached
  for 24 hours. Normal startup reuses a fresh cache; the Settings "Ricarica dal
  provider" action forces a full catalog refresh.
- macOS app icons in
  `native/flutter/leleg_iptv/macos/Runner/Assets.xcassets/AppIcon.appiconset`
  are generated from `src-tauri/app-icon.png` so the Flutter app uses the Leleg
  icon instead of the default Flutter icon.

Verified commands:

```bash
cd native/flutter/leleg_iptv
flutter analyze
flutter build macos --debug
```

Known test note: ordinary `flutter test` widget tests cannot load
`Mpv.framework` outside an app bundle. The generated smoke test is skipped with
an explicit note; validate playback with `flutter run -d macos` or a macOS
build.

Suggested layers:

```text
lib/
  main.dart
  app.dart
  domain/
    xtream_api.dart
    models.dart
    playback_item.dart
  data/
    xtream_client.dart
    storage.dart
  playback/
    playback_controller.dart
    track_models.dart
  screens/
    login_screen.dart
    home_screen.dart
    live_screen.dart
    movies_screen.dart
    series_screen.dart
    player_screen.dart
```

The native app should call Xtream APIs directly. Do not embed the Astro web app
inside Flutter.

## Current guardrails

- Web release is the stability baseline.
- Do not re-enable `ENABLE_TAURI_NATIVE_PLAYBACK` for user builds.
- Do not add more popup/external-player fallbacks as primary playback.
- Native player must be an actual in-app player screen.
- Playback engine ownership must live in the native app layer.
