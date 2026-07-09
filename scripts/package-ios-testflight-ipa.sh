#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/native/flutter/leleg_iptv"
OUT_DIR="${ROOT_DIR}/www/downloads/current"
EXPORT_PLIST="${APP_DIR}/ios/ExportOptions-TestFlight.plist"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
TEAM_ID="${APPLE_TEAM_ID:-PD57DH2235}"
BUILD_NAME="${BUILD_NAME:-}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
FLUTTER_BIN="${FLUTTER_BIN:-}"

if [[ -z "${BUILD_NAME}" ]]; then
  BUILD_NAME="$(awk '/^version:/ {print $2}' "${APP_DIR}/pubspec.yaml" | cut -d+ -f1)"
fi

if [[ -z "${FLUTTER_BIN}" ]]; then
  for candidate in \
    "$(command -v flutter 2>/dev/null || true)" \
    "/opt/homebrew/share/flutter/bin/flutter" \
    "/opt/homebrew/bin/flutter" \
    "${HOME}/development/flutter/bin/flutter" \
    "${HOME}/flutter/bin/flutter"; do
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
      FLUTTER_BIN="${candidate}"
      break
    fi
  done
fi

if [[ -z "${FLUTTER_BIN}" || ! -x "${FLUTTER_BIN}" ]]; then
  echo "Flutter not found. Set FLUTTER_BIN=/path/to/flutter and retry." >&2
  exit 1
fi

if [[ "${SKIP_DISTRIBUTION_IDENTITY_CHECK:-0}" != "1" ]]; then
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Eq '"(Apple Distribution|iOS Distribution):'; then
    cat >&2 <<'EOF'
Missing Apple/iOS Distribution signing identity.

Create or install an Apple Distribution certificate before building a TestFlight IPA:
  Xcode > Settings > Accounts > select the Apple Developer team > Manage Certificates > + > Apple Distribution

If Xcode says the team has no permission to create App Store profiles, open
App Store Connect / Apple Developer as the Account Holder or enable access to
Certificates, Identifiers & Profiles for this Apple ID.

Set SKIP_DISTRIBUTION_IDENTITY_CHECK=1 only if you know xcodebuild can create
or access the distribution identity through another configured account.
EOF
    exit 1
  fi
fi

if [[ ! -f "${EXPORT_PLIST}" ]]; then
  echo "Missing ${EXPORT_PLIST}" >&2
  exit 1
fi

TMP_EXPORT_PLIST="$(mktemp "${TMPDIR:-/tmp}/leleg-testflight-export.XXXXXX.plist")"
trap 'rm -f "${TMP_EXPORT_PLIST}"' EXIT
python3 - "${EXPORT_PLIST}" "${TMP_EXPORT_PLIST}" "${TEAM_ID}" <<'PY'
import plistlib
import sys

source, dest, team_id = sys.argv[1:4]
with open(source, "rb") as fh:
    data = plistlib.load(fh)
data["teamID"] = team_id
with open(dest, "wb") as fh:
    plistlib.dump(data, fh)
PY

cd "${APP_DIR}"
"${FLUTTER_BIN}" config --no-enable-swift-package-manager >/dev/null
"${FLUTTER_BIN}" pub get
"${FLUTTER_BIN}" build ios \
  --release \
  --no-codesign \
  --config-only \
  --build-name "${BUILD_NAME}" \
  --build-number "${BUILD_NUMBER}" \
  --dart-define "LELEG_BUILD_ID=${BUILD_NUMBER}"

pod install --project-directory=ios

ARCHIVE_PATH="${APP_DIR}/build/ios/archive/LelegIPTV.xcarchive"
EXPORT_PATH="${APP_DIR}/build/ios/testflight"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}"

AUTH_ARGS=()
if [[ -n "${ASC_API_KEY_PATH:-}" && -n "${ASC_API_KEY:-}" && -n "${ASC_API_ISSUER:-}" ]]; then
  AUTH_ARGS=(
    -authenticationKeyPath "${ASC_API_KEY_PATH}"
    -authenticationKeyID "${ASC_API_KEY}"
    -authenticationKeyIssuerID "${ASC_API_ISSUER}"
  )
fi

xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=NO \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${TMP_EXPORT_PLIST}" \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}

IPA_SOURCE="$(find "${EXPORT_PATH}" -maxdepth 1 -name '*.ipa' -print | head -1)"
if [[ -z "${IPA_SOURCE}" || ! -f "${IPA_SOURCE}" ]]; then
  echo "IPA not found under ${EXPORT_PATH}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
cp "${IPA_SOURCE}" "${OUT_DIR}/LelegIPTV-ios-testflight.ipa"

(
  cd "${OUT_DIR}"
  find . -maxdepth 1 -type f ! -name 'SHA256SUMS*.txt' -print0 \
    | xargs -0 shasum -a 256 > SHA256SUMS.txt
)

echo "Created ${OUT_DIR}/LelegIPTV-ios-testflight.ipa"
echo "Version ${BUILD_NAME} (${BUILD_NUMBER})"
