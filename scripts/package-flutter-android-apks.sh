#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/native/flutter/leleg_iptv"
OUT_DIR="${ROOT_DIR}/www/downloads/current"
MOBILE_APK="${APP_DIR}/build/app/outputs/flutter-apk/app-mobile-release.apk"
MOBILE_OUT="${OUT_DIR}/LelegIPTV-android-mobile-release.apk"
LEGACY_UNIVERSAL="${OUT_DIR}/LelegIPTV-android-universal-release.apk"

cd "${APP_DIR}"
flutter build apk --release --flavor mobile

mkdir -p "${OUT_DIR}"
cp "${MOBILE_APK}" "${MOBILE_OUT}"
# Rimuovi il vecchio nome fuorviante se presente.
rm -f "${LEGACY_UNIVERSAL}"

(
  cd "${OUT_DIR}"
  find . -maxdepth 1 -type f ! -name 'SHA256SUMS*.txt' -print0 \
    | xargs -0 shasum -a 256 > SHA256SUMS.txt
)

echo "Packaged:"
echo "  ${MOBILE_OUT}"
