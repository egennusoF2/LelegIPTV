#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/native/flutter/leleg_iptv/build/macos/Build/Products/Debug/leleg_iptv.app"
DEST_APP="/Applications/LelegIPTV.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing Flutter macOS app: $SOURCE_APP" >&2
  echo "Run: cd native/flutter/leleg_iptv && flutter build macos --debug" >&2
  exit 1
fi

echo "Removing old installed Leleg IPTV apps..."
rm -rf "/Applications/LelegIPTV.app"
rm -rf "/Applications/leleg_iptv.app"
rm -rf "$ROOT_DIR/src-tauri/gen/apple/build/arm64-sim/LelegIPTV.app"
rm -rf "$ROOT_DIR/src-tauri/target/release/bundle/macos/LelegIPTV.app"

echo "Installing fresh debug app..."
cp -R "$SOURCE_APP" "$DEST_APP"
rm -rf "$SOURCE_APP"

echo "Installed: $DEST_APP"
