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

- Tauri mobile target initialized with `pnpm tauri:ios:init`.
- Development run with `pnpm tauri:ios:dev`.
- Release build with `pnpm tauri:ios:build`.
- Generated Xcode project is expected under `src-tauri/gen/ios` after init.
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

Tauri iOS generated files are not committed until the target is initialized.
Use:

```bash
pnpm tauri:ios:init
pnpm tauri:ios:dev
pnpm tauri:ios:build
```

Expected generated root after init: `src-tauri/gen/ios`.

Implementation rules:

- Treat `src-tauri/gen/ios` as generated platform scaffolding.
- Keep all frontend Tauri API calls guarded for web preview and unsupported
  mobile contexts.
- Desktop-only Rust commands remain behind cfg gates; iOS cannot launch MPV/VLC
  processes like desktop.
- Validate playback on real device/simulator because HLS/DASH/native media
  support differs from Android WebView and desktop Chromium.

## Samsung Tizen TV packaging

Tizen TV is not a Tauri target. It is packaged as a Web application built from
the Astro static output.

Files:

- `packaging/tizen/config.xml`: W3C/Tizen Web App metadata with TV profile,
  internet privilege, start page, app name, icon, and wildcard provider access.
- `packaging/tizen/README.md`: packaging flow and runtime notes.
- `scripts/prepare-tizen.mjs`: copies `dist` into `build/tizen-web`, adds
  `config.xml`, and copies `icon.png`.

Commands:

```bash
pnpm build
pnpm tizen:prepare
```

The output root is `build/tizen-web`. Sign and package that folder with Tizen
Studio or Tizen CLI using the Samsung certificate profile for the target TV.

Runtime constraints:

- No Tauri plugins, Rust commands, desktop updater, tray, or external process
  launcher.
- Provider network calls use the browser fetch path.
- Playback depends on Samsung TV Web Runtime media support plus embedded JS
  backends; verify HLS, DASH, and MPEG-TS on real TV firmware.
- D-pad/spatial navigation, focus rings, overscan, and TV performance mode are
  mandatory release checks.

Known limitation:

- The current Tizen package is a Web App, not a native media app.
- Do not assume hls.js/Shaka/browser playback on Samsung firmware behaves like
  Chrome desktop.
- The recommended next Tizen implementation is a `webapis.avplay` backend with
  browser playback as fallback, as described in
  `08-native-playback-rebuild-strategy.md`.

## Native change checklist

1. Identify desktop vs Android vs iOS vs Tizen/web behavior.
2. Update Rust command registration in `lib.rs` if adding commands.
3. Update Tauri capabilities.
4. Add frontend guards for unavailable native APIs.
5. Add Rust unit tests for pure/native helper logic where possible.
6. Run frontend tests for corresponding JS wrappers.
7. Manually verify `pnpm tauri dev`, `pnpm tauri:android`,
   `pnpm tauri:ios:dev`, or `pnpm tizen:prepare` when the target environment is
   available.

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
- iOS/iPhone native app: Tauri iOS command path wired through `tauri:ios:*`;
  initialize generated Xcode project with `pnpm tauri:ios:init`.
- iPadOS native app: same Tauri iOS target, with existing iPad screenshot
  profiles available for responsive validation.
- Samsung Tizen TV app: Web App package path through
  `pnpm build && pnpm tizen:prepare`, then Tizen Studio/CLI signing into `.wgt`.
- tvOS native app.
- Roku, Fire TV native outside Android compatibility, Samsung Tizen, LG webOS,
  Apple Vision Pro native, Xbox, PlayStation.
