#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/native/flutter/leleg_iptv/build/ios/iphoneos/Runner.app"
OUT_DIR="${ROOT_DIR}/www/downloads/current"
WORK_DIR="${ROOT_DIR}/.tmp/unsigned-ipa"
IPA_PATH="${OUT_DIR}/LelegIPTV-ios-unsigned.ipa"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "Missing ${APP_DIR}"
  echo "Run first: cd native/flutter/leleg_iptv && flutter build ios --release --no-codesign"
  exit 1
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/Payload" "${OUT_DIR}"
cp -R "${APP_DIR}" "${WORK_DIR}/Payload/Runner.app"

# Sideload tools sign the payload themselves. Ensure no stale signature
# survives from a local Xcode build.
find "${WORK_DIR}/Payload/Runner.app" -name _CodeSignature -type d -prune -exec rm -rf {} +
find "${WORK_DIR}/Payload/Runner.app" -name embedded.mobileprovision -type f -delete

(
  cd "${WORK_DIR}"
  /usr/bin/zip -qry "${IPA_PATH}" Payload
)

echo "Created ${IPA_PATH}"
