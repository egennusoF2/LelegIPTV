#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT_DIR}/public/icon-512.png"
FLUTTER_DIR="${ROOT_DIR}/native/flutter/leleg_iptv"
ANDROID_TV_RES="${ROOT_DIR}/native/android-tv/app/src/main/res"
TMP_DIR="${ROOT_DIR}/.tmp/flutter-icons"

if [[ ! -f "${SOURCE}" ]]; then
  echo "Missing canonical icon: ${SOURCE}" >&2
  exit 1
fi

resize_png() {
  local size="$1"
  local out="$2"
  mkdir -p "$(dirname "${out}")"
  sips -s format png -z "${size}" "${size}" "${SOURCE}" --out "${out}" >/dev/null
}

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

# Android launcher icons.
resize_png 48 "${FLUTTER_DIR}/android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
resize_png 72 "${FLUTTER_DIR}/android/app/src/main/res/mipmap-hdpi/ic_launcher.png"
resize_png 96 "${FLUTTER_DIR}/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png"
resize_png 144 "${FLUTTER_DIR}/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png"
resize_png 192 "${FLUTTER_DIR}/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"

# Android TV native launcher (same brand icon as Flutter).
resize_png 48 "${ANDROID_TV_RES}/mipmap-mdpi/ic_launcher.png"
resize_png 72 "${ANDROID_TV_RES}/mipmap-hdpi/ic_launcher.png"
resize_png 96 "${ANDROID_TV_RES}/mipmap-xhdpi/ic_launcher.png"
resize_png 144 "${ANDROID_TV_RES}/mipmap-xxhdpi/ic_launcher.png"
resize_png 192 "${ANDROID_TV_RES}/mipmap-xxxhdpi/ic_launcher.png"

# iOS app icons.
IOS_DIR="${FLUTTER_DIR}/ios/Runner/Assets.xcassets/AppIcon.appiconset"
resize_png 20 "${IOS_DIR}/Icon-App-20x20@1x.png"
resize_png 40 "${IOS_DIR}/Icon-App-20x20@2x.png"
resize_png 60 "${IOS_DIR}/Icon-App-20x20@3x.png"
resize_png 29 "${IOS_DIR}/Icon-App-29x29@1x.png"
resize_png 58 "${IOS_DIR}/Icon-App-29x29@2x.png"
resize_png 87 "${IOS_DIR}/Icon-App-29x29@3x.png"
resize_png 40 "${IOS_DIR}/Icon-App-40x40@1x.png"
resize_png 80 "${IOS_DIR}/Icon-App-40x40@2x.png"
resize_png 120 "${IOS_DIR}/Icon-App-40x40@3x.png"
resize_png 120 "${IOS_DIR}/Icon-App-60x60@2x.png"
resize_png 180 "${IOS_DIR}/Icon-App-60x60@3x.png"
resize_png 76 "${IOS_DIR}/Icon-App-76x76@1x.png"
resize_png 152 "${IOS_DIR}/Icon-App-76x76@2x.png"
resize_png 167 "${IOS_DIR}/Icon-App-83.5x83.5@2x.png"
resize_png 1024 "${IOS_DIR}/Icon-App-1024x1024@1x.png"

# macOS app icons.
MAC_DIR="${FLUTTER_DIR}/macos/Runner/Assets.xcassets/AppIcon.appiconset"
resize_png 16 "${MAC_DIR}/app_icon_16.png"
resize_png 32 "${MAC_DIR}/app_icon_32.png"
resize_png 64 "${MAC_DIR}/app_icon_64.png"
resize_png 128 "${MAC_DIR}/app_icon_128.png"
resize_png 256 "${MAC_DIR}/app_icon_256.png"
resize_png 512 "${MAC_DIR}/app_icon_512.png"
resize_png 1024 "${MAC_DIR}/app_icon_1024.png"

# Windows desktop icon.
ICONSET="${TMP_DIR}/app.iconset"
mkdir -p "${ICONSET}"
resize_png 16 "${ICONSET}/icon_16x16.png"
resize_png 32 "${ICONSET}/icon_16x16@2x.png"
resize_png 32 "${ICONSET}/icon_32x32.png"
resize_png 64 "${ICONSET}/icon_32x32@2x.png"
resize_png 128 "${ICONSET}/icon_128x128.png"
resize_png 256 "${ICONSET}/icon_128x128@2x.png"
resize_png 256 "${ICONSET}/icon_256x256.png"
resize_png 512 "${ICONSET}/icon_256x256@2x.png"
resize_png 512 "${ICONSET}/icon_512x512.png"
resize_png 1024 "${ICONSET}/icon_512x512@2x.png"
if iconutil -c icns "${ICONSET}" -o "${TMP_DIR}/app_icon.icns" 2>/dev/null; then
  cp "${TMP_DIR}/app_icon.icns" "${FLUTTER_DIR}/macos/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon.icns" 2>/dev/null || true
fi
if [[ -f "${FLUTTER_DIR}/windows/runner/resources/app_icon.ico" ]]; then
  echo "Windows ICO already present: ${FLUTTER_DIR}/windows/runner/resources/app_icon.ico"
else
  echo "Warning: Windows ICO missing. Generate it from ${SOURCE} on Windows before a Windows release." >&2
fi

# Tizen launcher icon. Samsung TV accepts PNG; 192px is enough for the package
# manifest icon and avoids shipping the old Flutter placeholder.
resize_png 192 "${FLUTTER_DIR}/tizen/shared/res/ic_launcher.png"
resize_png 192 "${ROOT_DIR}/native/tizen-tv/public/icon.png"

# Flutter web fallback icons.
resize_png 32 "${FLUTTER_DIR}/web/favicon.png"
resize_png 192 "${FLUTTER_DIR}/web/icons/Icon-192.png"
resize_png 512 "${FLUTTER_DIR}/web/icons/Icon-512.png"
resize_png 192 "${FLUTTER_DIR}/web/icons/Icon-maskable-192.png"
resize_png 512 "${FLUTTER_DIR}/web/icons/Icon-maskable-512.png"

rm -rf "${TMP_DIR}"
echo "Flutter brand icons synced from ${SOURCE}"
