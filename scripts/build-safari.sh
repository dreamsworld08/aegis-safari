#!/usr/bin/env bash
# Build the Aegis Safari app + extension for Apple Silicon (arm64). Requires macOS with Xcode 15+.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Aegis"
BUNDLE_ID="${BUNDLE_ID:-dev.aegis.safari}"
OUT="build"

rm -rf "$OUT"
xcrun safari-web-extension-converter extension \
  --project-location "$OUT" --app-name "$APP" --bundle-identifier "$BUNDLE_ID" \
  --macos-only --swift --copy-resources --no-open --no-prompt --force

# Replace the generated handler with the Keychain bridge.
HANDLER="$(find "$OUT" -name SafariWebExtensionHandler.swift | head -1)"
cp native/SafariWebExtensionHandler.swift "$HANDLER"

PROJ="$(find "$OUT" -maxdepth 2 -name '*.xcodeproj' | head -1)"
xcodebuild -project "$PROJ" -scheme "$APP" -configuration Release \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  -derivedDataPath "$OUT/DerivedData" ${SIGN_ARGS:-CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO} build

APP_PATH="$(find "$OUT/DerivedData" -name "$APP.app" -type d | head -1)"
echo "Built: $APP_PATH"
echo "Run it once, then enable Aegis in Safari ▸ Settings ▸ Extensions."
