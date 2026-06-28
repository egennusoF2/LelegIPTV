#!/usr/bin/env bash
# Avvia un solo emulatore Android TV (evita istanze duplicate che fanno crashare adb).

set -euo pipefail

AVD="${TV_AVD:-LelegIPTV_AndroidTV_API34}"
EMULATOR="${ANDROID_EMULATOR:-$HOME/Library/Android/sdk/emulator/emulator}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"

# Chiudi eventuali istanze zombie solo se adb non risponde
if pgrep -f "qemu-system.*${AVD}" >/dev/null 2>&1; then
  if "$ADB" devices 2>/dev/null | grep -q "emulator.*device"; then
    "$ADB" wait-for-device shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
    echo "Emulatore già attivo."
    exit 0
  fi
  echo "Chiusura istanza bloccata di $AVD..."
  pkill -f "qemu-system.*${AVD}" || true
  sleep 3
fi

echo "Avvio $AVD..."
nohup "$EMULATOR" -avd "$AVD" -no-snapshot -gpu host -no-audio -no-boot-anim \
  >> /tmp/tv-emulator.log 2>&1 &

for i in $(seq 1 60); do
  sleep 2
  if "$ADB" devices 2>/dev/null | grep -q "emulator.*device"; then
    "$ADB" wait-for-device shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
    echo "Emulatore pronto ($i)."
    exit 0
  fi
done

echo "Timeout: emulatore non raggiungibile. Controlla /tmp/tv-emulator.log" >&2
exit 1
