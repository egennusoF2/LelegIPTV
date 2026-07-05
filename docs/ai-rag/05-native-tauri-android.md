# Native Tauri, Android, iOS, and Tizen guide

## Tauri startup

File: `src-tauri/src/lib.rs`

`run()` builds the app with common plugins:

- notification
- clipboard-manager
- store
- http
- fs
- dialog
- opener

Desktop-only additions:

- window-state plugin
- updater plugin
- Discord RPC state and commands
- external player state and command
- tray command

Android-only addition:

- `tauri-plugin-android-fs`

iOS/iPadOS target:

- Legacy Tauri iOS commands are no longer the release path.
- Current iOS/iPadOS release work uses Flutter:
  `pnpm flutter:ios:build` followed by `pnpm flutter:ios:package`.
- Generated Xcode project is expected under `native/flutter/leleg_iptv/ios`.
- Requires macOS, Xcode, Apple signing, and simulator/device validation.

Setup behavior:

- Debug desktop logging.
- Sweep orphan MPV sockets on desktop.
- Install tray on desktop.
- Hide native decorations, enable shadow, show/focus main window.

## Desktop tray

File: `src-tauri/src/tray.rs`

Responsibilities:

- Install system tray icon and menu.
- Left-click toggles main window.
- Menu navigates to Live TV, Movies, Series, Search, Guide, Downloads, Settings.
- Emits `xt:tray:navigate` route event to frontend.
- Intercepts close request and hides window when close-to-tray is enabled.
- Exposes command `set_close_to_tray(enabled)`.

Frontend counterpart: `src/scripts/lib/tray-handler.ts`.

Settings counterpart: `src/scripts/lib/app-settings.js`.

## External player bridge

File: `src-tauri/src/external_player.rs`

Tauri command:

```rust
launch_external_player(path, args, mode, reuse)
```

Modes:

- `detect`: run binary with `--version`, timeout after 2 seconds.
- `exists`: verify path exists.
- `launch`: spawn or reuse external player.

Error prefixes:

- `NOT_FOUND`
- `PERMISSION`
- `TIMEOUT`
- `OTHER`
- `IPC` for reuse IPC send failures internally.

MPV reuse:

- Creates socket/pipe endpoint.
- Adds `--input-ipc-server=<endpoint>` and `--idle=yes`.
- Sends JSON IPC `loadfile` command on subsequent launches.
- Encodes user-agent/referrer in MPV percent-length option syntax.
- Cleans stale slots and old Unix sockets.

VLC reuse:

- Adds `--one-instance` and `--no-playlist-enqueue`.
- Removes `--play-and-exit`.
- Tracks pid liveness.

Safety:

- Path and args reject NUL/newline/carriage return.
- Process spawn is shell-free.
- Unit tests cover argv augmentation, IPC command construction, validation,
  path checks, lock behavior, pid zero.

Frontend counterpart: `src/scripts/lib/player-runtime.ts`,
`src/components/PlayerPicker.svelte`.

## Discord Rich Presence bridge

File: `src-tauri/src/discord.rs`

Commands:

- `discord_set_activity`
- `discord_clear`
- `discord_disconnect`

Behavior:

- Lazily opens Discord IPC client per configured app/client ID.
- Reuses active client until client ID changes.
- Supports details, state text, large/small assets, timestamps, and up to two
  buttons.
- Desktop-only by cfg gate.

Frontend counterpart: `src/scripts/lib/discord-rpc.js`,
settings in `app-settings.js`.

## Android bridge

File: `src-tauri/gen/android/app/src/main/java/com/lelegiptv/player/MainActivity.kt`

Responsibilities:

- Host Tauri Android WebView activity.
- Expose JavaScript interfaces used by frontend for Android-specific behavior.
- Support Android intent playback handoff.
- Support device/platform/status-bar information used by layout and player.

Frontend counterpart:

- `src/scripts/lib/player-runtime.ts` for Android handoff.
- `src/scripts/lib/android-fs.js` for Android filesystem plugin use.
- `src/layouts/Layout.astro` for Android platform/status-bar first-paint logic.

Android playback notes:

- Embedded playback can handle HLS, DASH, MPEG-TS, and native formats when the
  WebView/runtime supports the required JavaScript player path.
- Android external handoff uses MIME hints from `androidMimeForUrl()`:
  `.m3u8` -> `application/vnd.apple.mpegurl`, `.mpd` ->
  `application/dash+xml`, `.ts` -> `video/mp2t`, plus common file formats.
- VLC can be launched directly when installed; otherwise the system intent
  chooser is used.

Known limitation:

- Android currently does not have an integrated native media player backend.
  It is still WebView plus JavaScript players plus external intent handoff.
- Treat local VOD/HLS or transcode paths as unsupported on Android unless a
  real FFmpeg binary/library or a native player bridge exists for the target
  build.
- The recommended next Android implementation is a Media3/ExoPlayer backend
  behind the shared playback contract described in
  `08-native-playback-rebuild-strategy.md`.

## Capabilities and permissions

Files:

- `src-tauri/capabilities/default.json`
- `src-tauri/capabilities/desktop.json`
- `src-tauri/capabilities/android.json`

Rules:

- Add new permissions deliberately.
- Keep desktop-only commands out of Android where not supported.
- Test command availability from frontend guards.
- Do not assume Tauri plugin is available in web preview.
- `native_playback_status` is currently registered only on desktop in
  `src-tauri/src/lib.rs`. Android and iOS do not expose it; frontend code must
  tolerate `getNativePlaybackStatus()` returning `null`.

## Android generated files

Tauri Android generated files live under `src-tauri/gen/android`.

Important files:

- `app/build.gradle.kts`
- `build.gradle.kts`
- `settings.gradle`
- `gradle.properties`
- `AndroidManifest.xml`
- `network_security_config.xml`
- `file_paths.xml`
- `buildSrc/.../BuildTask.kt`
- `buildSrc/.../RustPlugin.kt`

Treat most of this as generated platform scaffolding. Edit only when platform
behavior requires it and verify Tauri Android still builds.

## iOS generated files

The active iOS generated files live under the Flutter project. Use:

```bash
pnpm flutter:ios:build
pnpm flutter:ios:package
```

Expected generated root: `native/flutter/leleg_iptv/ios`.

Implementation rules:

- Treat Flutter build outputs as generated platform scaffolding.
- Keep all frontend Tauri API calls guarded for web preview and unsupported
  mobile contexts.
- Desktop-only Rust commands remain behind cfg gates; iOS cannot launch MPV/VLC
  processes like desktop.
- Validate playback on real device/simulator because HLS/DASH/native media
  support differs from Android WebView and desktop Chromium.

## Samsung Tizen TV packaging

Tizen TV is not a Tauri target. The current release is the dedicated TypeScript
TV app packaged as a Samsung `.wgt`; do not use the old Astro or Flutter Tizen
packages as the release path.

Files:

- `native/tizen-tv/config.xml`: package identity, CSP and TV privileges.
- `native/tizen-tv/src/player/avplay.ts`: Samsung AVPlay lifecycle, tracks,
  display rectangles and playback state.
- `native/tizen-tv/src/ui/virtualList.ts`: bounded channel/category rendering.
- `native/tizen-tv/src/app/focusManager.ts`: deterministic D-pad navigation.

Commands:

```bash
cd native/tizen-tv
npm install
npm run build
npm run package:wgt
```

The signed artifact is `native/tizen-tv/build/LelegIPTV-tizen-tv.wgt` and is
also copied to `www/downloads/current/LelegIPTV-tizen-tv-release.wgt`.

Runtime constraints:

- No Tauri plugins, Rust commands, desktop updater or tray.
- Fullscreen playback must use Samsung AVPlay.
- Keep Samsung's default adaptive bitrate and buffering values. Forcing
  `STARTBITRATE=HIGHEST` with a small custom buffer produced freezes on
  variable IPTV streams.
- D-pad/remote navigation, focus rings, overscan and TV performance mode are
  mandatory release checks.
- Poster batches must receive explicit directional handlers. Falling back to
  geometric DOM searches on every key press causes progressively slower
  navigation as the catalogue grows.

Known limitation:

- AVPlay HTTP headers are limited by the TV API, so providers that require
  non-standard headers must be verified on real TV firmware.
- Keep Tizen playback isolated from Flutter macOS/iOS/Android branches.

## Native change checklist

1. Identify desktop vs Android vs iOS vs Tizen/web behavior.
2. Update Rust command registration in `lib.rs` if adding commands.
3. Update Tauri capabilities.
4. Add frontend guards for unavailable native APIs.
5. Add Rust unit tests for pure/native helper logic where possible.
6. Run frontend tests for corresponding JS wrappers.
7. Manually verify `pnpm flutter:analyze`, `pnpm flutter:android:build`,
   `pnpm flutter:ios:build`, or `pnpm flutter:tizen:build` /
   `flutter-tizen run` when the target environment is available.

## Release target matrix

The repository can currently target these app/device families:

- Web/static browser build: `pnpm build` output, useful for development and
  hosted preview, without Tauri-only APIs.
- Windows desktop app: Tauri desktop build, supports tray, updater, external
  MPV/VLC, filesystem, notifications, Discord RPC.
- macOS desktop app: same Tauri desktop capability set, with platform-specific
  packaging/signing outside this code summary.
- Linux desktop app: same Tauri desktop capability set, subject to distro
  packaging requirements.
- Android phone app: Tauri Android/WebView with Android FS bridge, intent
  playback handoff, responsive mobile layout.
- Android tablet app: same Android package, larger responsive layout.
- Android TV / Google TV app: Android package plus D-pad/spatial navigation,
  overscan settings, TV performance mode, and TV screenshot profiles.
- Chromebook: Android/WebView package or browser/PWA-style deployment, validated
  by Chromebook screenshot profile.
- Android XR: Android large-screen target represented by screenshot profile;
  verify input/focus behavior separately before release.
- iOS/iPhone native app: Flutter command path wired through
  `flutter:ios:*`; package unsigned IPA with `pnpm flutter:ios:package`.
- iPadOS native app: same Flutter iOS target, with tablet layout selected at
  runtime and physical iPad validation before release.
- Samsung Tizen TV app: Flutter native package path through
  `pnpm flutter:tizen:build`, then Tizen Studio/CLI installation of `.tpk`.
- tvOS native app.
- Roku, Fire TV native outside Android compatibility, Samsung Tizen, LG webOS,
  Apple Vision Pro native, Xbox, PlayStation.
