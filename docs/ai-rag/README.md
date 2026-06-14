# Leleg IPTV AI RAG index

This folder is a retrieval-oriented knowledge base for AI agents working on
Leleg IPTV. It is intentionally redundant: each document repeats key
terms, paths, events, and module names so semantic search can retrieve useful
chunks without needing the whole repository in context.

## Recommended retrieval order

1. `00-project-brief.md` for the product, stack, runtime model, and rules.
2. `01-runtime-flows.md` for end-to-end flows such as login, catalog loading,
   EPG loading, playback, external players, downloads, backup, and sync.
3. `02-file-catalog.md` for file-by-file responsibility lookup.
4. `03-shared-modules.md` for shared library contracts and events.
5. `04-frontend-pages-components.md` for route/component ownership.
6. `05-native-tauri-android.md` for Rust/Tauri/Android ownership.
7. `06-testing-and-change-playbooks.md` for safe change procedures.
8. `07-events-storage-cache-index.md` for event, storage, and cache lookup.
9. `08-native-playback-rebuild-strategy.md` for the reset plan for non-web
   playback, including MaxVideoPlayer lessons and the native backend strategy.
10. `09-native-reset-flutter-media-kit.md` for the current decision to keep the
    web app stable and rebuild native apps with Flutter + `media_kit`.
11. `10-flutter-web-parity-checklist.md` for the native Flutter vs web feature
    parity matrix, including EPG, Settings, player, favorites, watch later, and
    remaining porting order.

## Scope

Covered:

- `src/pages`
- `src/components`
- `src/layouts`
- `src/scripts`
- `src/plugins`
- `src/types`
- `src-tauri/src`
- `src-tauri/capabilities`
- selected Android bridge/build files under `src-tauri/gen/android`
- `tests`
- `docs/src`
- maintenance scripts under `scripts`

Excluded from detailed behavioral summaries:

- lockfiles, binary icons, image assets, generated Gradle wrapper JARs
- localization JSON content in full; locale files are cataloged as data assets

## Important local docs

- `docs/AI_AGENT_GUIDE.md`: higher-level architecture and AI collaboration guide.
- `docs/SYNC_UPSTREAM.md`: fork alignment workflow.
- `scripts/sync-upstream.sh`: local fork alignment script.
- `docs/ai-rag/08-native-playback-rebuild-strategy.md`: current strategic
  source of truth for rebuilding app releases that do not behave like the web
  release.
- `docs/ai-rag/09-native-reset-flutter-media-kit.md`: current native reset
  decision after the failed Tauri/WebView/libmpv integration attempt.
- `docs/ai-rag/10-flutter-web-parity-checklist.md`: current checklist for
  matching the Flutter native app to the web app route by route.
