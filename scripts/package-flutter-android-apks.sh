#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/native/flutter/leleg_iptv"
OUT_DIR="${ROOT_DIR}/www/downloads/current"
MOBILE_APK="${APP_DIR}/build/app/outputs/flutter-apk/app-mobile-release.apk"
MOBILE_OUT="${OUT_DIR}/LelegIPTV-android-mobile-release.apk"
LEGACY_UNIVERSAL="${OUT_DIR}/LelegIPTV-android-universal-release.apk"

cd "${APP_DIR}"
# Incremental Flutter builds can ship stale kernel snapshots (e.g. removed widgets
# like _EpgGrid still present in the APK). Always clean before release packaging.
flutter clean
flutter pub get
flutter build apk --release --flavor mobile

apk_contains() {
  local pattern="$1"
  set +o pipefail
  strings -a "${MOBILE_APK}" | grep -m1 -q "${pattern}"
  local found=$?
  set -o pipefail
  return "${found}"
}

if apk_contains '_EpgGrid@'; then
  echo "ERROR: APK still contains legacy timeline EPG (_EpgGrid). Aborting." >&2
  exit 1
fi
if ! apk_contains 'TvGuideLayout'; then
  echo "ERROR: APK missing new guide layout (TvGuideLayout). Aborting." >&2
  exit 1
fi

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
