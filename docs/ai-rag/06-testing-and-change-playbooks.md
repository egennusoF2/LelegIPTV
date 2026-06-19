# Testing and change playbooks

## Baseline commands

```bash
pnpm test
pnpm lint
pnpm build
```

Native/manual commands when environment supports them:

```bash
pnpm flutter:analyze
pnpm flutter:android:build
pnpm flutter:ios:build
pnpm flutter:tizen:build
```

## Before editing

1. Run `git status --short`.
2. Preserve user changes; do not revert unrelated files.
3. Read the route/component and the owning `src/scripts/lib` module, or the
   Flutter screen/service under `native/flutter/leleg_iptv`.
4. Search existing events before inventing new events.

## Adding a playlist feature

Read first:

- `src/scripts/lib/creds.js`
- `src/scripts/lib/preferences.js`
- `src/scripts/lib/cache.js`
- relevant route script

Checklist:

- Decide whether data is global, playlist-scoped, or cache-scoped.
- Extend the owning module, not page-local ad hoc storage.
- Dispatch a DOM event after mutation.
- Invalidate cache if provider data shape changes.
- Update backup/restore if persisted user setting matters.
- Add tests for pure helpers.

## Adding provider/network behavior

Read first:

- `provider-fetch.js`
- `xtream-api.js`
- `retry.ts`
- `provider-error.js`
- `diagnostic.ts`

Checklist:

- Use `providerFetch()` for IPTV provider requests.
- Use `xtreamApiFetch()` for Xtream API actions.
- Redact URLs in logs.
- Add retry/backoff only where idempotent and useful.
- Handle arrays and wrapper object result shapes.
- Render provider errors through existing UI helpers.

## Adding playback behavior

Read first:

- Web: `player-runtime.ts`, `stream-urls.ts`, `stream-headers.ts`
- Native: `native/flutter/leleg_iptv/lib/core/playback/**`
- Platform wrappers: `native/flutter/leleg_iptv/android/**`,
  `native/flutter/leleg_iptv/ios/**`, `native/flutter/leleg_iptv/tizen/**`

Checklist:

- Keep URL building pure.
- Test web playback separately from Flutter native playback.
- Guard Android phone/tablet/TV, iOS/iPadOS, desktop, and Tizen behavior.
- Preserve progress tracking, audio/subtitle selection, fullscreen behavior, and
  download handoff.

## Adding EPG behavior

Read first:

- `epg-data.js`
- `epg-worker.ts`
- `epg/epg.ts`
- `epg/mapping.ts`
- `preferences.js`

Checklist:

- Preserve source precedence.
- Preserve waterfall merge semantics.
- Do not block main thread for large XMLTV where worker path exists.
- Include playlist ID in cache keys and events.
- Update mapping behavior if changing tvg-id resolution.

## Adding settings

Read first:

- `app-settings.js`
- `Layout.astro`
- `settings.astro`
- relevant Svelte card/editor
- `backup.js`

Checklist:

- Add getter/setter in `app-settings.js`.
- Dispatch event on setter.
- If first-paint visible, mirror setting in `Layout.astro` inline script.
- Add UI control and i18n keys.
- Include in backup import/export if user expects portability.
- Guard native side effects.

## Adding UI text

Read first:

- `i18n.ts`
- `src/i18n/en.json`
- nearby locale usage

Checklist:

- Use `data-i18n`/`data-i18n-attr` in Astro/HTML.
- Use `t()` in scripts/Svelte.
- Add `en.json` key.
- Mirror key to other locale files if possible.
- Avoid hard-coded visible strings in dynamic UI.

## Adding category/filter behavior

Read first:

- `category-picker.ts`
- `preferences.js`
- route script for target kind

Checklist:

- Use existing hidden/allowed/category mode APIs.
- Include kind and playlist ID in mutations.
- Refresh pseudo rows for favorites/recents where needed.
- Listen to `xt:hidden-categories-changed`, `xt:allowed-categories-changed`,
  `xt:category-mode-changed`.

## Adding downloads behavior

Read first:

- `downloads.js`
- `android-fs.js`
- `app-settings.js`
- `downloads.astro`

Checklist:

- Support desktop and Android separately.
- Maintain sidecar metadata.
- Dispatch list/progress/throughput events.
- Respect concurrency.
- Do not assume local filesystem paths on Android content URIs.

## Testing map

Existing tests:

- `tests/m3u-parser.test.ts`: parser fixtures.
- `tests/epg-data.test.ts`: EPG pure helpers.
- `tests/player-runtime.test.ts`: player args/errors.
- `tests/log.test.ts`: logging/redaction.

Suggested new tests:

- URL builders in `stream-urls.ts` for any stream URL change.
- Preferences snapshot/restore for persisted state changes.
- Category picker pure filtering if extracted.
- Provider error classification for new provider failure cases.
- EPG source resolution for new EPG settings.

## Manual verification scenarios

Live TV:

- Add Xtream playlist.
- Add M3U playlist.
- Switch playlist.
- Play live channel.
- Toggle favorite.
- Open EPG side panel.
- Test external player button.

Movies:

- Load VOD list.
- Filter/search/sort.
- Open detail.
- Resume playback.
- Add to watchlist.
- Start download.

Series:

- Load series list.
- Open detail.
- Play episode.
- Verify progress badge on list.

EPG:

- Load full grid.
- Refresh source.
- Change timezone offset.
- Open programme dialog.
- Map channel manually.

Settings:

- Edit playlist.
- Change locale.
- Toggle perf mode.
- Change player backend.
- Export/import backup.

Native:

- Close-to-tray on desktop.
- Tray navigation.
- MPV/VLC path detection.
- Android external intent handoff.

## Common failure patterns

- Browser global used during Astro build or Vitest.
- Raw provider fetch blocked by CORS/WebView differences.
- Cache not invalidated after playlist edit.
- Event missing playlist ID or kind.
- M3U-only playlist code tries Xtream VOD/series APIs.
- Android path assumes desktop Tauri plugin.
- UI text added without locale keys.
- First-paint setting changed only after hydration causing flicker.
- Virtualized list row height changed without updating math/focus.
