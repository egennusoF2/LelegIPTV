<p align="center">
  <img src="https://raw.githubusercontent.com/egennusoF2/LelegIPTV/refs/heads/main/src-tauri/icons/128x128@2x.png" alt="LelegIPTV app icon - cross-platform IPTV player"/>
</p>

<h1 align="center">LelegIPTV</h1>

<p align="center"><strong>A cross-platform IPTV player for Xtream Codes and M3U / M3U8 playlists.</strong></p>

<p align="center">
  Live TV with EPG, movies, series, offline downloads, and TV-remote (D-pad) navigation.<br/>
  Builds local artifacts for Windows, macOS, Linux, Android, Android TV, iOS, iPadOS, Samsung Tizen TV, and the web.
</p>

<p align="center">
  <a href="#build-artifacts">
    <img src="https://img.shields.io/badge/Desktop-Tauri%20artifacts-2563eb?logo=tauri&logoColor=white" height="50" alt="Build desktop artifacts"/>
  </a>
  <a href="#build-artifacts">
    <img src="https://img.shields.io/badge/Mobile-Android%20%7C%20iOS-0891b2?logo=android&logoColor=white" height="50" alt="Build mobile artifacts"/>
  </a>
  <a href="#build-artifacts">
    <img src="https://img.shields.io/badge/TV-Android%20TV%20%7C%20Tizen-0ea5e9?logo=samsung&logoColor=white" height="50" alt="Build TV artifacts"/>
  </a>
</p>

<p align="center">
  <a href="https://github.com/egennusoF2/LelegIPTV/releases/latest"><img src="https://img.shields.io/github/v/release/egennusoF2/LelegIPTV?label=latest&color=a855f7" alt="Latest release"/></a>
  <a href="https://github.com/egennusoF2/LelegIPTV/releases"><img src="https://img.shields.io/github/downloads/egennusoF2/LelegIPTV/total?color=a855f7&cacheSeconds=300" alt="GitHub downloads"/></a>
  <a href="https://github.com/egennusoF2/LelegIPTV/stargazers"><img src="https://img.shields.io/github/stars/egennusoF2/LelegIPTV?color=a855f7" alt="GitHub stars"/></a>
  <img src="https://img.shields.io/badge/platforms-Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20Android%20%7C%20iOS%20%7C%20Tizen%20TV-64748b?color=a855f7" alt="Supported platforms: Windows, macOS, Linux, Android, iOS, and Tizen TV"/>
</p>

<p align="center">
  <a href="https://github.com/egennusoF2/LelegIPTV/issues"><img src="https://img.shields.io/github/issues/egennusoF2/LelegIPTV?logo=github&color=a855f7" alt="Issues"/></a>
  <a href="https://github.com/egennusoF2/LelegIPTV/discussions"><img src="https://img.shields.io/github/discussions/egennusoF2/LelegIPTV?logo=github&color=a855f7" alt="Discussions"/></a>
</p>

## Screenshots

<p align="center">
  <img src="docs/screenshots/Desktop/home.png" alt="LelegIPTV home screen showing Live TV, Movies, and Series tiles with Continue Watching strip" width="780"/>
</p>

<details>
<summary>More screenshots (Live TV, EPG, Movies, Series, Android TV, mobile)</summary>

**Desktop**

| | | |
|---|---|---|
| <img src="docs/screenshots/Desktop/livetv.png" alt="Live TV channel list with inline EPG showing now/next programmes"/> | <img src="docs/screenshots/Desktop/movies.png" alt="Movies poster grid with category filtering"/> | <img src="docs/screenshots/Desktop/series.png" alt="Series detail view with seasons and episodes"/> |
| <img src="docs/screenshots/Desktop/epg.png" alt="Full XMLTV schedule grid for the EPG page"/> | <img src="docs/screenshots/Desktop/settings.png" alt="Settings page with playlists, display, network, and downloads"/> | <img src="docs/screenshots/Desktop/favorites.png" alt="Favorites page showing the cross-playlist union of starred items"/> |

**Android TV (10-foot UI, D-pad focus)**

| | | |
|---|---|---|
| <img src="docs/screenshots/Android-TV/home.png" alt="LelegIPTV home screen on Android TV"/> | <img src="docs/screenshots/Android-TV/livetv.png" alt="Live TV on Android TV with D-pad focus on the channel list"/> | <img src="docs/screenshots/Android-TV/movies.png" alt="Movies poster grid on Android TV"/> |

**Phone (portrait, touch)**

| | | |
|---|---|---|
| <img src="docs/screenshots/Galaxy-S20-Ultra/home.png" alt="LelegIPTV home screen on a phone in portrait" width="240"/> | <img src="docs/screenshots/Galaxy-S20-Ultra/livetv.png" alt="Live TV on a phone with bottom navigation" width="240"/> | <img src="docs/screenshots/Galaxy-S20-Ultra/series.png" alt="Series poster grid on a phone in portrait" width="240"/> |

</details>

## Features

- **Two backends, one UI.** Sign in with Xtream Codes credentials (host / port / user / pass) or paste a direct `.m3u` / `.m3u8` URL. The app detects the mode automatically.
- **Live TV** with category filtering, channel search, virtualised list, and inline EPG (now / next / today).
- **Movies (VOD)** and **Series** library with poster grids, detail dialogs, and season / episode navigation.
- **Full schedule grid** on the EPG page, with timezone-aware "all times local" rendering.
- **Embedded playback** for HLS, DASH, MPEG-TS, and browser-native media where the target runtime supports them.
- **Multiple playlists**, switchable from the sidebar without re-entering credentials.
- **TV-first navigation.** Spatial focus (D-pad / arrow keys) is wired across the whole app via `spatial-navigation-polyfill`. Hit targets, focus rings, and reflow tested for 10-foot UI.
- **Light and dark themes**, both first-class. Honours `prefers-color-scheme`, `prefers-reduced-motion`, and `prefers-contrast`.
- **Adjustable font scale** (Default / Medium / Large / X-Large) plus a responsive root size that scales the whole UI on 4K and 8K displays.
- **Desktop artifacts** via Tauri for Windows, macOS, and Linux, with updater metadata when configured.
- **Offline-friendly persistence.** Credentials and preferences live in the OS app-data dir on Tauri builds, with a localStorage / cookie fallback on the web build.

## Build artifacts

LelegIPTV is a fork-oriented build: documentation points to local artifacts generated by this repository, not to Microsoft Store, Google Play, App Store, or Samsung Store listings.

| Target OS / device | Build command | Local artifact path |
| --- | --- | --- |
| Web browser / hosted static app | `pnpm build` | `dist/` |
| Windows 10 / Windows 11 | `pnpm tauri build` on Windows | `src-tauri/target/release/bundle/nsis/*.exe`, `src-tauri/target/release/bundle/msi/*.msi` |
| macOS Apple Silicon / Intel | `pnpm tauri build` on macOS | `src-tauri/target/release/bundle/dmg/*.dmg`, `src-tauri/target/release/bundle/macos/*.app` |
| Linux Debian / Ubuntu / Mint | `pnpm tauri build` on Linux | `src-tauri/target/release/bundle/deb/*.deb` |
| Linux Fedora / openSUSE / RHEL | `pnpm tauri build` on Linux | `src-tauri/target/release/bundle/rpm/*.rpm` |
| Linux portable | `pnpm tauri build` on Linux | `src-tauri/target/release/bundle/appimage/*.AppImage` |
| Android phone / tablet | `pnpm tauri:android:build` | `src-tauri/gen/android/app/build/outputs/apk/**/*.apk`, `src-tauri/gen/android/app/build/outputs/bundle/**/*.aab` |
| Android TV / Google TV | `pnpm tauri:android:build` | Same Android `.apk` / `.aab`; validate D-pad, overscan, and TV playback before sideload/release |
| Chromebook | `pnpm tauri:android:build` or `pnpm build` | Android `.apk` / `.aab` for Play-compatible devices, or `dist/` for browser deployment |
| Android XR | `pnpm tauri:android:build` | Same Android `.apk` / `.aab`; validate large-screen focus and playback separately |
| iOS / iPhone | `pnpm tauri:ios:init`, then `pnpm tauri:ios:build` on macOS | `src-tauri/gen/apple/build/**/*.xcarchive`, exported `.ipa`, or the Xcode Organizer archive/export path configured locally |
| iPadOS / iPad | `pnpm tauri:ios:build` on macOS | Same iOS `.ipa` / Xcode archive path; validate tablet layout and media playback |
| Samsung Tizen TV | `pnpm build && pnpm tizen:prepare`, then package with Tizen Studio/CLI | Prepared root: `build/tizen-web/`; signed package from Tizen tooling: `*.wgt` |

### Desktop artifacts

Tauri desktop builds are host-platform specific. Build Windows artifacts on Windows, macOS artifacts on macOS, and Linux artifacts on Linux unless you maintain a dedicated cross-compilation setup.

```bash
pnpm tauri build
```

### Android artifacts

Requires Android Studio/SDK, NDK, Java, and the Tauri Android target already initialized under `src-tauri/gen/android`.

```bash
pnpm tauri:android:build
```

### iOS and iPadOS artifacts

Requires macOS, Xcode, Apple signing, and the Tauri iOS target. The first command generates the local Xcode project under `src-tauri/gen/apple`.

```bash
pnpm tauri:ios:init
pnpm tauri:ios:build
```

### Samsung Tizen TV artifacts

Tizen TV is packaged as a Web application, not as a Tauri target. Prepare the project root locally, then sign/package it with Tizen Studio or the Tizen CLI using your Samsung certificate profile.

```bash
pnpm build
pnpm tizen:prepare
tizen package -t wgt -s <certificate-profile> -- build/tizen-web
```

### macOS: "LelegIPTV.app" cannot be opened

The macOS build is not yet notarized by Apple, so Gatekeeper blocks it on first launch with a message like _"Apple could not verify LelegIPTV.app is free of malware"_. After dragging the app from the `.dmg` into `/Applications`, remove the quarantine flag from a Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/LelegIPTV.app"
```

Then open the app normally. You only need to do this once per install.

## Develop

Requirements: [pnpm](https://pnpm.io) (the package manager is pinned in `package.json`), Node 20+, the Rust toolchain for Tauri desktop, Android Studio/SDK for Android and Android TV, Xcode on macOS for iOS/iPadOS, and Tizen Studio/CLI for Samsung Tizen TV packages.

```bash
pnpm install
pnpm dev                  # Astro + Svelte at http://localhost:4321
pnpm tauri dev            # Native desktop shell (auto-spawns pnpm dev)
pnpm tauri:android        # Android dev shell
pnpm tauri:ios:dev        # iOS dev shell, after pnpm tauri:ios:init
```

To test the dev server on another device on the LAN (phone, TV), set `XTREAM_HMR_HOST` to your machine's LAN IP so Vite advertises the right HMR host:

```bash
XTREAM_HMR_HOST=192.168.1.50 pnpm dev
```

Tests run with Vitest (`pnpm test`); the suite covers pure-function libs in `tests/`. Lint with ESLint flat config (`pnpm lint` / `pnpm lint:fix`); no Prettier. TypeScript is in strict mode (`tsconfig.json` extends `astro/tsconfigs/strict`); the `@/*` alias maps to `src/*`.

## Credits

Copyright (c) 2025 Ludovico Ferrara.

## License

LelegIPTV is released under the [GNU General Public License v3.0 or later](LICENSE). You are free to use, study, share, and modify it; any distributed fork or derivative must remain under the same license and ship its source.
