#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/native/android-tv"
OUTPUT="$ROOT/www/downloads/current/LelegIPTV-android-tv-release.apk"

cd "$PROJECT"
./gradlew assembleRelease

mkdir -p "$(dirname "$OUTPUT")"
cp app/build/outputs/apk/release/app-release.apk "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"

echo "APK TV nativo: $OUTPUT"
