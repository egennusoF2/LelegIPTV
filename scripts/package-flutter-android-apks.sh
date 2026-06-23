#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/native/flutter/leleg_iptv"
OUT_DIR="${ROOT_DIR}/www/downloads/current"
MOBILE_APK="${APP_DIR}/build/app/outputs/flutter-apk/app-mobile-release.apk"
TV_APK="${APP_DIR}/build/app/outputs/flutter-apk/app-tv-release.apk"

cd "${APP_DIR}"
flutter build apk --release --flavor mobile
flutter build apk --release --flavor tv --dart-define=LELEG_ANDROID_TV=true

mkdir -p "${OUT_DIR}"
cp "${MOBILE_APK}" "${OUT_DIR}/LelegIPTV-android-universal-release.apk"
cp "${TV_APK}" "${OUT_DIR}/LelegIPTV-android-tv-release.apk"

(
  cd "${OUT_DIR}"
  find . -maxdepth 1 -type f ! -name 'SHA256SUMS*.txt' -print0 \
    | xargs -0 shasum -a 256 > SHA256SUMS.txt
)

echo "Packaged:"
echo "  ${OUT_DIR}/LelegIPTV-android-universal-release.apk"
echo "  ${OUT_DIR}/LelegIPTV-android-tv-release.apk"
