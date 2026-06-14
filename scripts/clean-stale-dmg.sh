#!/usr/bin/env bash
# Unmount leftover Tauri/create-dmg volumes and remove rw.*.dmg temps from failed builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_BUNDLE="${ROOT}/src-tauri/target/release/bundle/macos"
DMG_BUNDLE="${ROOT}/src-tauri/target/release/bundle/dmg"

if command -v hdiutil >/dev/null 2>&1; then
  while IFS= read -r mount_dir; do
    [[ -n "$mount_dir" ]] || continue
    echo "[clean-dmg] detaching $mount_dir"
    hdiutil detach "$mount_dir" -force 2>/dev/null || true
  done < <(
    hdiutil info 2>/dev/null | awk '/\/Volumes\/dmg\./ {print $NF}' | sort -u
  )

  while IFS= read -r image_path; do
    [[ -n "$image_path" ]] || continue
    echo "[clean-dmg] detaching image $image_path"
    hdiutil detach "$image_path" -force 2>/dev/null || true
  done < <(
    hdiutil info 2>/dev/null | awk '
      /^image-path/ && /rw\..*LelegIPTV.*\.dmg/ { print $NF }
    ' | sort -u
  )
fi

if [[ -d "$MACOS_BUNDLE" ]]; then
  find "$MACOS_BUNDLE" -maxdepth 1 -name 'rw.*.dmg' -print -delete 2>/dev/null || true
fi

if [[ -d "$DMG_BUNDLE" ]]; then
  find "$DMG_BUNDLE" -maxdepth 1 -name 'rw.*.dmg' -print -delete 2>/dev/null || true
fi
