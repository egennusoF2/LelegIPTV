#!/usr/bin/env bash
# Avvia l'emulatore Android TV in modo stabile (cold boot, no snapshot, GPU software).
set -euo pipefail

AVD_NAME="${AVD_NAME:-LelegIPTV_AndroidTV_API34}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
EMULATOR="$ANDROID_HOME/emulator/emulator"
ADB="$ANDROID_HOME/platform-tools/adb"

if [[ ! -x "$EMULATOR" ]]; then
  echo "Emulator non trovato: $EMULATOR" >&2
  exit 1
fi

# Evita istanze duplicate che fanno crashare qemu/adb.
if "$ADB" devices 2>/dev/null | rg -q "emulator-[0-9]+.*device"; then
  echo "Emulatore già connesso:"
  "$ADB" devices -l
  exit 0
fi

# Patch AVD: cold boot + snapshot disabilitati (API 36 + snapshot = crash frequenti).
AVD_INI="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
if [[ -f "$AVD_INI" ]]; then
  perl -i -pe '
    s/^fastboot\.forceColdBoot=.*/fastboot.forceColdBoot=yes/;
    s/^fastboot\.forceFastBoot=.*/fastboot.forceFastBoot=no/;
    s/^firstboot\.bootFromLocalSnapshot=.*/firstboot.bootFromLocalSnapshot=no/;
    s/^firstboot\.saveToLocalSnapshot=.*/firstboot.saveToLocalSnapshot=no/;
    s/^hw\.gpu\.enabled=.*/hw.gpu.enabled=yes/;
    s/^hw\.gpu\.mode=.*/hw.gpu.mode=swiftshader_indirect/;
    s/^hw\.ramSize=.*/hw.ramSize=4096/;
  ' "$AVD_INI"
fi

echo "Avvio $AVD_NAME (cold boot, swiftshader, API 34 consigliato)..."
WINDOW_OPT=""
if [[ "${SHOW_WINDOW:-}" != "1" ]]; then
  WINDOW_OPT="-no-window"
fi
nohup "$EMULATOR" \
  -avd "$AVD_NAME" \
  $WINDOW_OPT \
  -no-snapshot-load \
  -no-snapshot-save \
  -no-boot-anim \
  -gpu swiftshader_indirect \
  -feature -Vulkan \
  -memory 4096 \
  -cores 2 \
  > /tmp/leleg-android-tv-emulator.log 2>&1 &

echo "Log: /tmp/leleg-android-tv-emulator.log"
echo ""
echo "Suggerimenti stabilità:"
echo "  - Usa AVD API 34 (default), non API 36 (Angle instabile → crash GPU)."
echo "  - Per test app: flutter build apk --debug --flavor tv (Impeller disabilitato in debug)."
echo "  - Per finestra visibile: SHOW_WINDOW=1 $0"
echo ""
echo "Attendo boot completo..."
for i in $(seq 1 120); do
  if "$ADB" wait-for-device shell getprop sys.boot_completed 2>/dev/null | rg -q '^1$'; then
    echo "Emulatore pronto (${i}s)."
    "$ADB" devices -l
    exit 0
  fi
  sleep 2
done

echo "Timeout boot emulatore. Ultime righe log:" >&2
tail -40 /tmp/leleg-android-tv-emulator.log >&2 || true
exit 1
