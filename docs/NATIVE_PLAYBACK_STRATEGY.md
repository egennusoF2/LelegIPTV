# Native playback strategy

This document resets the strategy for Leleg IPTV app releases after comparing
the current codebase with `MaxMB15/MaxVideoPlayer`.

## Executive summary

The web version works because it runs in the environment it was designed for:
browser playback with HLS/Shaka/hls.js/native `<video>`.

The app releases are failing because they try to use WebView as if it were a
full IPTV/VOD media engine. That is not a stable foundation for MKV, MPEG-TS,
multi-audio, embedded subtitles, duration, seeking, and resume across macOS,
iOS, Android, Android TV, and Samsung Tizen.

The right reset is:

1. Keep the current web app as the stable baseline.
2. Keep the shared UI/catalog/EPG/settings code.
3. Introduce a shared playback contract.
4. Implement platform-specific playback backends behind that contract.
5. Use external players only as fallback, not as the primary app experience.

## What MaxVideoPlayer teaches

MaxVideoPlayer uses Tauri and React, but the video engine is not the browser.
Its desktop builds embed `libmpv` directly into the native window:

- macOS: `libmpv` rendered into `NSOpenGLView`.
- Linux: `libmpv` rendered through EGL/X11/Wayland surfaces.
- React is the UI/control layer.
- Rust owns playback state, duration, seek, reconnect, subtitles, and player
  commands.

This is the key design difference. MaxVideoPlayer does not ask WKWebView to
decode everything. It uses a native media engine and lets the web frontend
control it.

Important MaxVideoPlayer reference areas:

- `crates/tauri-plugin-mpv/src/engine.rs`
- `crates/tauri-plugin-mpv/src/mpv.rs`
- `crates/tauri-plugin-mpv/src/macos.rs`
- `apps/desktop/src/hooks/useMpv.ts`
- `apps/desktop/src/lib/tauri.ts`
- `apps/desktop/src/components/player/VideoPlayer.tsx`

Important warning: MaxVideoPlayer Android and iOS support is not production in
the referenced repo. Those files are stubs/plans. Use it as a desktop-native
architecture reference, not as a finished mobile implementation.

## Current Leleg IPTV state

Current playback-related files:

- `src/scripts/lib/player-runtime.ts`
- `src/scripts/lib/embedded-vod-playback.ts`
- `src/scripts/lib/embedded-hls-tracks.ts`
- `src/scripts/lib/embedded-shaka-tracks.ts`
- `src/scripts/lib/embedded-native-tracks.ts`
- `src/scripts/lib/embedded-vod-subtitles.ts`
- `src-tauri/src/media_proxy.rs`
- `src-tauri/src/external_player.rs`
- `src-tauri/gen/android/app/src/main/java/com/lelegiptv/player/MainActivity.kt`
- `packaging/tizen/config.xml`
- `scripts/prepare-tizen.mjs`

The current implementation contains many competing media paths:

- ArtPlayer
- native `<video>`
- hls.js
- Shaka
- dash.js
- mpegts.js
- Rust loopback proxy
- FFmpeg remux/transcode endpoints
- local VOD HLS cache
- subtitle extraction endpoint
- MPV/VLC external launch
- Android intent handoff

This complexity is not the solution; it is the symptom. These paths need to be
organized behind one playback abstraction.

## Target playback contract

Create one interface that every backend implements:

```ts
interface PlaybackSession {
  load(source: PlaybackSource, options?: PlaybackLoadOptions): Promise<void>
  play(): Promise<void>
  pause(): Promise<void>
  stop(): Promise<void>
  seek(seconds: number): Promise<void>
  setVolume(volume: number): Promise<void>
  selectAudioTrack(id: string): Promise<void>
  selectSubtitleTrack(id: string | null): Promise<void>
  setSubtitleDelay(seconds: number): Promise<void>
  getState(): Promise<PlaybackState>
  destroy(): Promise<void>
}
```

Every backend should expose:

- current position
- duration
- loading/buffering state
- ended state
- error code/message
- audio tracks
- subtitle tracks
- selected tracks
- first-frame event

## Implementation checkpoint

The first contract entry point now exists in:

- `src/scripts/lib/playback-session.ts`

Current behavior is intentionally conservative:

- `mountPlaybackSession(...)` is the factory used by movies, series, and live TV.
- `WebPlaybackSession` wraps the existing web player runtime, so the working web
  release remains the default.
- The contract now exposes a normalized track snapshot through `getTracks()`,
  `selectAudioTrack(...)`, `selectSubtitleTrack(...)`, and standard playback
  events through `on(...)`.
- `NativePlaybackSession` is already implemented on the frontend side. It calls
  the reserved Tauri native commands, polls `native_playback_state`, and emits
  the same `xt:playback:*` events. It is mounted only when Rust reports both
  `available: true` and `integrated: true`; the current build therefore still
  uses `WebPlaybackSession`.
- `NativePlaybackSession` also exposes a Video.js-shaped `handle` facade so the
  current movies/series/live pages do not crash when the native backend is
  eventually enabled. The facade delegates `src`, `play`, `pause`, `seek`,
  `duration`, `currentTime`, events, and `dispose` to the native session.
- `NativePlaybackSession` now tracks the player element bounds and calls
  `native_playback_attach` with `getBoundingClientRect()` plus device scale.
  This is the bridge where the native macOS view is attached before playback.
- Tauri desktop exposes `native_playback_status` from
  `src-tauri/src/native_playback.rs`.
- That module now contains an MPV JSON IPC backend. If `mpv` is installed, it can
  spawn/control MPV, load URLs, play/pause/stop/seek, set volume, select
  audio/subtitle tracks, set subtitle delay, and read state/tracks from MPV.
- The same Rust module now exposes `native_playback_attach`. On macOS it
  validates that Tauri can provide `NSWindow*` and `NSView*` for the main
  WebView and stores the frontend-reported media rectangle. It intentionally
  returns `attached: false` until a real `libmpv` rendering view exists.
- The backend still reports `integrated: false`, because the video surface is
  not embedded inside the Tauri window yet. Do not set it to `true` until
  `libmpv` renders a real first frame in the Tauri window.
- As a temporary working macOS app path, movies and series running inside Tauri
  auto-launch MPV for VOD playback unless the URL contains `embedded=1`.
  This gives reliable native playback, duration, seeking, audio tracks, and
  subtitles through MPV while the in-window video surface is still pending. This
  remains an escape/bridge, not the final UX.
- Desktop also registers the future native command surface:
  `native_playback_attach`,
  `native_playback_load`, `native_playback_play`, `native_playback_pause`,
  `native_playback_stop`, `native_playback_seek`,
  `native_playback_set_volume`, `native_playback_select_audio_track`,
  `native_playback_select_subtitle_track`,
  `native_playback_set_subtitle_delay`, and `native_playback_state`. These
  commands use MPV IPC when available, or return a stable unavailable/not-loaded
  error when the engine is missing or no media has been loaded.

Future app-release work should extend `PlaybackSession` instead of adding more
conditional playback branches inside detail pages or `player-runtime.ts`.

## Platform plan

| Platform | Recommended backend | Notes |
|---|---|---|
| Web | Current web backend: Shaka/hls.js/native video | Keep stable. This is the baseline. |
| macOS | Tauri + embedded `libmpv` or AVPlayer bridge | For IPTV/provider compatibility, `libmpv` is the strongest option. |
| Linux | Tauri + embedded `libmpv` | MaxVideoPlayer has a useful reference. |
| Windows | WebView2 + fallback first, then MPV backend | Do not promise robust VOD until native backend exists. |
| Android phone/tablet | Tauri shell + Media3/ExoPlayer bridge | Better track selection, duration, buffering, subtitles, TV support. |
| Android TV / Fire TV | ExoPlayer primary | Remote control and fullscreen must be native-aware. |
| iOS/iPadOS | Tauri shell + AVPlayer bridge | Strong for HLS/MP4; MKV remains a hard limitation unless converted/server-supported. |
| Samsung Tizen TV | Web App + Samsung AVPlay adapter | Tizen is not Tauri; use `webapis.avplay` where available. |

## What to stop doing

Do not keep adding isolated fixes that make one case look better while making
another platform worse:

- guessing `.mp4` siblings as the main solution
- treating local FFmpeg HLS generation as the primary app playback path
- launching VLC as the normal macOS UX
- using provider duration as real media duration
- duplicating audio/subtitle menus from several helpers
- assuming Android/iOS/Tizen WebView equals desktop Chrome

These can remain diagnostics or fallback paths, but they should not be the
architecture.

## Practical rebuild phases

### Phase 1: freeze web

Keep the web release working. Add tests around source selection, HLS/Shaka
tracks, subtitles, resume, and common VOD/live cases.

### Phase 2: introduce the contract

Add a `PlaybackSession` abstraction in `src/scripts/lib`. Move the current web
playback code behind `WebPlaybackSession` without changing user behavior.

### Phase 3: macOS prototype

Build a minimal native playback prototype before integrating it into all pages:

1. load one VOD URL
2. show native video under/inside the Tauri window
3. play/pause/seek
4. read duration/time
5. list audio/subtitle tracks
6. select track
7. resume position

Only after this works should movies/series/live use it.

### Phase 4: Android/Android TV prototype

Add Media3/ExoPlayer bridge and map it to the same contract. Test on a real
phone first, then Android TV/remote.

### Phase 5: iOS prototype

Add AVPlayer bridge for HLS/MP4 and map media selection groups to the shared
track model.

### Phase 6: Tizen prototype

Add a Tizen-only AVPlay backend with browser fallback. Test on real Samsung TV.

## Test matrix before calling any app release ready

Each platform backend must pass:

- live HLS
- live MPEG-TS
- VOD MP4
- VOD MKV or explicit unsupported message
- series episode
- multi-audio source
- subtitle source
- seek to the middle
- resume after leaving and re-entering
- play/pause
- network stall/reconnect
- fullscreen
- platform back button or remote back key

If a backend does not pass this matrix on real hardware, it is not production
ready.
