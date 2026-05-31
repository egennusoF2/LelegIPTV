# Samsung Tizen TV packaging

Tizen TV is packaged as a Web application, not as a Tauri target. The app is
built with Astro, prepared into a Tizen project root, then signed and packaged
with Tizen Studio or the Tizen CLI.

## Prepare

```bash
pnpm build
pnpm tizen:prepare
```

The prepared project root is `build/tizen-web` and contains:

- `index.html` and static assets copied from `dist`.
- `config.xml` copied from `packaging/tizen/config.xml`.
- `icon.png` copied from `src-tauri/icons/128x128.png` when present.

## Package

Use Tizen Studio or the Tizen CLI with your Samsung certificate profile. A
typical CLI flow is:

```bash
tizen package -t wgt -s <certificate-profile> -- build/tizen-web
```

Keep `config.xml` in the project root. Samsung/Tizen packaging requires this
metadata file alongside the web assets.

## Runtime notes

- No Tauri plugins are available on Tizen TV.
- Provider requests use the browser/web path.
- Playback must rely on the TV browser media stack plus the embedded JS
  backends. HLS/DASH support depends on the target TV firmware.
- Remote-control and D-pad behavior should be tested on a real Samsung TV or
  Tizen TV emulator before release.
