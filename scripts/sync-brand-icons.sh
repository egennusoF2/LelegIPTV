#!/usr/bin/env bash
# Regenerate platform icons from src-tauri/app-icon.png and refresh web assets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/src-tauri/app-icon.png"
ICONS="$ROOT/src-tauri/icons"
GEN_IOS="$ROOT/src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset"
PUBLIC="$ROOT/public"

if [[ ! -f "$MASTER" ]]; then
  echo "Missing master icon: $MASTER" >&2
  exit 1
fi

echo "→ tauri icon (desktop, android, ios png sets)…"
pnpm --dir "$ROOT" tauri icon "$MASTER" -o "$ICONS"

echo "→ iOS Xcode asset catalog…"
cp -f "$ICONS"/ios/*.png "$GEN_IOS"/

echo "→ Android gen mipmaps…"
for d in hdpi mdpi xhdpi xxhdpi xxxhdpi; do
  cp -f "$ICONS/android/mipmap-$d"/ic_launcher*.png \
    "$ROOT/src-tauri/gen/android/app/src/main/res/mipmap-$d"/
done

echo "→ Web favicons…"
cp -f "$ICONS/icon.ico" "$PUBLIC/favicon.ico"
sips -z 180 180 "$MASTER" --out "$PUBLIC/apple-touch-icon.png" >/dev/null
sips -z 32 32 "$MASTER" --out "$PUBLIC/favicon-32.png" >/dev/null
sips -z 192 192 "$MASTER" --out "$PUBLIC/icon-192.png" >/dev/null
sips -z 512 512 "$MASTER" --out "$PUBLIC/icon-512.png" >/dev/null

echo "Done. Rebuild native apps to refresh dock/home icons:"
echo "  macOS:  pnpm build:desktop   (or pnpm tauri dev after quit old app)"
echo "  iOS:    pnpm tauri:ios:dev:device"
echo "  Android: pnpm build:android"
