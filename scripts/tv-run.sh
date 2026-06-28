#!/usr/bin/env bash
# Avvia emulatore TV (se serve), builda, installa e lancia Leleg IPTV TV.
# Uso: ./scripts/tv-run.sh
#      ./scripts/tv-run.sh --no-build   (solo install + avvio)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AVD="${TV_AVD:-LelegIPTV_AndroidTV_API34}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
EMULATOR="${ANDROID_EMULATOR:-$HOME/Library/Android/sdk/emulator/emulator}"
APK="$ROOT/native/android-tv/app/build/outputs/apk/debug/app-debug.apk"
PACKAGE="com.lelegiptv.tv"
ACTIVITY=".MainActivity"
BUILD=1

for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    -h|--help)
      echo "Uso: $0 [--no-build]"
      exit 0
      ;;
  esac
done

adb_ready() {
  "$ADB" devices 2>/dev/null | grep -q "emulator.*device"
}

wait_boot() {
  "$ADB" wait-for-device
  local i
  for i in $(seq 1 90); do
    if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      return 0
    fi
    sleep 2
  done
  echo "ERRORE: emulatore avviato ma boot non completato." >&2
  exit 1
}

start_emulator() {
  if adb_ready; then
    echo "✓ Emulatore già connesso ($("$ADB" devices | grep emulator | awk '{print $1}'))"
    wait_boot
    return 0
  fi

  if pgrep -f "qemu-system.*${AVD}" >/dev/null 2>&1; then
    echo "⏳ Emulatore in avvio, attendo adb..."
    local i
    for i in $(seq 1 60); do
      sleep 2
      if adb_ready; then
        wait_boot
        echo "✓ Emulatore pronto."
        return 0
      fi
    done
    echo "ERRORE: processo emulatore attivo ma adb non risponde." >&2
    echo "Prova: pkill -f qemu-system; $0" >&2
    exit 1
  fi

  if [ ! -x "$EMULATOR" ]; then
    echo "ERRORE: emulatore non trovato in $EMULATOR" >&2
    echo "Installa Android SDK / imposta ANDROID_EMULATOR." >&2
    exit 1
  fi

  echo "▶ Avvio $AVD..."
  nohup "$EMULATOR" -avd "$AVD" -no-snapshot -gpu host -no-audio -no-boot-anim \
    >> /tmp/tv-emulator.log 2>&1 &

  for i in $(seq 1 60); do
    sleep 2
    if adb_ready; then
      wait_boot
      echo "✓ Emulatore pronto ($i)."
      return 0
    fi
  done

  echo "ERRORE: timeout avvio emulatore. Log: /tmp/tv-emulator.log" >&2
  exit 1
}

build_apk() {
  echo "▶ Build APK debug..."
  (cd "$ROOT/native/android-tv" && ./gradlew assembleDebug -q)
  if [ ! -f "$APK" ]; then
    echo "ERRORE: APK non generato in $APK" >&2
    exit 1
  fi
  echo "✓ APK: $APK"
}

install_and_launch() {
  echo "▶ Installazione..."
  if ! "$ADB" install -r "$APK"; then
    echo "ERRORE: installazione fallita. Emulatore connesso?" >&2
    "$ADB" devices -l
    exit 1
  fi
  echo "▶ Avvio app..."
  "$ADB" shell am start -n "${PACKAGE}/${ACTIVITY}"
  echo "✓ Fatto. Controlla la finestra emulatore (Cmd+Tab se non la vedi)."
}

start_emulator
if [ "$BUILD" -eq 1 ]; then
  build_apk
fi
if [ ! -f "$APK" ]; then
  echo "ERRORE: APK mancante. Esegui senza --no-build." >&2
  exit 1
fi
install_and_launch
