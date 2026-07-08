#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPA_PATH="${1:-${ROOT_DIR}/www/downloads/current/LelegIPTV-ios-testflight.ipa}"

if [[ ! -f "${IPA_PATH}" ]]; then
  echo "Missing IPA: ${IPA_PATH}" >&2
  echo "Run: bash scripts/package-ios-testflight-ipa.sh" >&2
  exit 1
fi

if [[ -n "${ASC_API_KEY:-}" && -n "${ASC_API_ISSUER:-}" ]]; then
  EXTRA=()
  if [[ -n "${ASC_API_KEY_PATH:-}" ]]; then
    EXTRA+=(--p8-file-path "${ASC_API_KEY_PATH}")
  fi
  xcrun altool \
    --upload-app \
    --type ios \
    --file "${IPA_PATH}" \
    --api-key "${ASC_API_KEY}" \
    --api-issuer "${ASC_API_ISSUER}" \
    "${EXTRA[@]}"
elif [[ -n "${APPLE_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
  xcrun altool \
    --upload-app \
    --type ios \
    --file "${IPA_PATH}" \
    --username "${APPLE_ID}" \
    --password "@env:APP_SPECIFIC_PASSWORD"
else
  cat >&2 <<'EOF'
Missing App Store Connect credentials.

Use API key auth:
  export ASC_API_KEY="ABC123DEFG"
  export ASC_API_ISSUER="00000000-0000-0000-0000-000000000000"
  export ASC_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABC123DEFG.p8"
  bash scripts/upload-ios-testflight.sh

Or Apple ID auth:
  export APPLE_ID="you@example.com"
  export APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
  bash scripts/upload-ios-testflight.sh
EOF
  exit 1
fi
