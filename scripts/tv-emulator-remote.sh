#!/usr/bin/env bash
# Controlla l'emulatore Android TV dal Mac quando tastiera/D-pad non arrivano alla finestra.
# Uso: ./scripts/tv-emulator-remote.sh [comando]
#      ./scripts/tv-emulator-remote.sh interactive

set -euo pipefail

ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
SERIAL="${ANDROID_SERIAL:-emulator-5554}"

key() {
  "$ADB" -s "$SERIAL" shell input keyevent "$1"
}

tap() {
  "$ADB" -s "$SERIAL" shell input tap "$1" "$2"
}

text() {
  # Spazi vanno come %s per adb input text
  local encoded
  encoded=$(printf '%s' "$*" | sed 's/ /%s/g')
  "$ADB" -s "$SERIAL" shell input text "$encoded"
}

interactive() {
  echo "Telecomando emulatore (q=esci)"
  echo "  frecce = D-pad   invio/spazio = OK   b = Back   h = Home   m = Menu"
  echo "  t = scrivi testo   l = Live TV   g = Guida TV"
  stty -echo -icanon time 0 min 0 2>/dev/null || true
  while true; do
    IFS= read -r -n 1 key || break
    case "$key" in
      $'\x1b')
        read -r -n 2 -t 0.05 rest || rest=""
        case "$rest" in
          '[A') key KEYCODE_DPAD_UP ;;
          '[B') key KEYCODE_DPAD_DOWN ;;
          '[C') key KEYCODE_DPAD_RIGHT ;;
          '[D') key KEYCODE_DPAD_LEFT ;;
          *) ;;
        esac
        ;;
      ''|$'\n'|' ') key KEYCODE_DPAD_CENTER ;;
      b|B) key KEYCODE_BACK ;;
      h|H) key KEYCODE_HOME ;;
      m|M) key KEYCODE_MENU ;;
      q|Q) break ;;
      t|T)
        stty echo icanon 2>/dev/null || true
        read -r -p "Testo: " line
        text "$line"
        stty -echo -icanon time 0 min 0 2>/dev/null || true
        ;;
      l|L)
        key KEYCODE_BACK
        sleep 0.2
        key KEYCODE_DPAD_DOWN
        key KEYCODE_DPAD_CENTER
        ;;
      g|G)
        key KEYCODE_BACK
        sleep 0.2
        for _ in 1 2 3 4 5; do key KEYCODE_DPAD_DOWN; done
        key KEYCODE_DPAD_CENTER
        ;;
      *) ;;
    esac
  done
  stty echo icanon 2>/dev/null || true
  echo
}

usage() {
  cat <<'EOF'
Controlla Android TV emulator via adb (Mac → emulatore).

Comandi:
  up down left right   D-pad
  ok enter center      Seleziona
  back                 Indietro
  home menu
  text Ciao mondo      Digita testo (focus su un campo prima)
  tap 960 540          Tap a coordinate
  interactive          Modalità telecomando da terminale
  launch               Avvia Leleg IPTV TV

Variabili: ADB, ANDROID_SERIAL (default emulator-5554)

Dopo aver abilitato hw.keyboard nell'AVD, riavvia l'emulatore (cold boot)
per usare anche le frecce del Mac direttamente nella finestra emulatore.
EOF
}

main() {
  if ! "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1; then
    echo "Emulatore $SERIAL non raggiungibile. Avvialo o imposta ANDROID_SERIAL." >&2
    exit 1
  fi

  case "${1:-help}" in
    up) key KEYCODE_DPAD_UP ;;
    down) key KEYCODE_DPAD_DOWN ;;
    left) key KEYCODE_DPAD_LEFT ;;
    right) key KEYCODE_DPAD_RIGHT ;;
    ok|enter|center) key KEYCODE_DPAD_CENTER ;;
    back) key KEYCODE_BACK ;;
    home) key KEYCODE_HOME ;;
    menu) key KEYCODE_MENU ;;
    play) key KEYCODE_MEDIA_PLAY_PAUSE ;;
    text)
      shift
      text "$*"
      ;;
    tap)
      tap "${2:?x}" "${3:?y}"
      ;;
    interactive|i) interactive ;;
    launch)
      "$ADB" -s "$SERIAL" shell am start -n com.lelegiptv.tv/.MainActivity
      ;;
    help|-h|--help) usage ;;
    *)
      echo "Comando sconosciuto: $1" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
