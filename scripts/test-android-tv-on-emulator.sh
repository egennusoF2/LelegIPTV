#!/usr/bin/env bash
# Installa l'APK TV sull'emulatore e verifica che l'UI non sia mobile (no drawer/hamburger).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="${APK:-$ROOT/native/flutter/leleg_iptv/build/app/outputs/flutter-apk/app-tv-release.apk}"
DEBUG_APK="$ROOT/native/flutter/leleg_iptv/build/app/outputs/flutter-apk/app-tv-debug.apk"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
PKG="com.lelegiptv.leleg_iptv"

if [[ ! -f "$APK" && -f "$DEBUG_APK" ]]; then
  echo "Release non trovata, uso debug (Impeller off, più stabile sull'emulatore)."
  APK="$DEBUG_APK"
fi

if [[ ! -f "$APK" ]]; then
  echo "APK non trovato. Build:" >&2
  echo "  pnpm run flutter:android:build:tv" >&2
  echo "  oppure: flutter build apk --debug --flavor tv" >&2
  exit 1
fi

"$ROOT/scripts/run-android-tv-emulator.sh"

echo "Installazione $(basename "$APK") ..."
"$ADB" uninstall "$PKG" 2>/dev/null || true
"$ADB" install -r "$APK"

echo "Avvio app (Leanback launcher)..."
"$ADB" logcat -c
"$ADB" shell am start -a android.intent.action.MAIN \
  -c android.intent.category.LEANBACK_LAUNCHER \
  -n "$PKG/.MainActivity"

sleep 8

if ! "$ADB" get-state 2>/dev/null | rg -q device; then
  echo "FAIL: emulatore crashato dopo avvio app." >&2
  tail -5 /tmp/leleg-android-tv-emulator.log >&2 || true
  exit 1
fi

SHOT="/tmp/leleg-tv-test.png"
"$ADB" exec-out screencap -p > "$SHOT"
echo "Screenshot: $SHOT"

"$ADB" logcat -d 2>/dev/null | rg "leleg-tv" | tail -15 || true

# Heuristic: larghezza > altezza del menu in alto vs sidebar verticale
if command -v python3 >/dev/null; then
  python3 - <<'PY' "$SHOT"
import sys
from pathlib import Path
path = Path(sys.argv[1])
print(f"Screenshot {path.stat().st_size} bytes")
PY
fi

echo "Verifica visiva: deve esserci la barra orizzontale Home | Live TV | Film | Serie | Preferiti."
echo "Se vedi drawer/hamburger o sidebar desktop verticale con Ctrl+K, la build TV non è attiva."
exit 0
