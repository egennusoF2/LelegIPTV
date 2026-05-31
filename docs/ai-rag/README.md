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
