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

# Extension: Keychain + updater-launch bridge.
cp native/SafariWebExtensionHandler.swift "$(find "$OUT" -name SafariWebExtensionHandler.swift | head -1)"

# Container app: window with the in-app updater.
cp native/app/ViewController.swift "$(find "$OUT" -name ViewController.swift -not -path '*Extension*' | head -1)"
MAIN_HTML="$(find "$OUT" -name Main.html -not -path '*Extension*' | head -1)"
[ -n "$MAIN_HTML" ] || { echo "error: generated Main.html not found" >&2; exit 1; }
MAIN_DIR="$(dirname "$MAIN_HTML")"
cp native/app/Main.html native/app/Script.js native/app/Style.css "$MAIN_DIR/"

PROJ="$(find "$OUT" -maxdepth 2 -name '*.xcodeproj' | head -1)"
[ -n "$PROJ" ] || { echo "error: no .xcodeproj in $OUT" >&2; find "$OUT" -maxdepth 3 >&2; exit 1; }
# Newer Xcode converters can give the app a bundle id that differs from the requested one
# (e.g. dev.aegis.Aegis), which breaks signed builds: the extension id must start with the app id.
target_id() {
  xcodebuild -project "$PROJ" -target "$1" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}'
}
APP_ID="$(target_id "$APP")"
echo "Bundle ids: app=$APP_ID extension=$(target_id "$APP Extension")"
if [ -n "$APP_ID" ] && [ "$APP_ID" != "$BUNDLE_ID" ]; then
  while IFS= read -r -d '' f; do
    perl -pi -e "s/\Q$APP_ID\E(?![\w-])/$BUNDLE_ID/g" "$f"
  done < <(grep -rIl --null -F "$APP_ID" "$PROJ" "$(dirname "$PROJ")/$APP" 2>/dev/null || true)
  APP_ID="$(target_id "$APP")"
  echo "Corrected app bundle id: $APP_ID"
  if [ "$APP_ID" != "$BUNDLE_ID" ]; then
    echo "error: could not set the app bundle id to $BUNDLE_ID. Matching project lines:" >&2
    grep -rIn -i "bundle_identifier\|aegis" "$PROJ" | head -20 >&2
    exit 1
  fi
fi

xcodebuild -project "$PROJ" -scheme "$APP" -configuration Release \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  -derivedDataPath "$OUT/DerivedData" ${SIGN_ARGS:-CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO} build

APP_PATH="$(find "$OUT/DerivedData" -name "$APP.app" -type d | head -1)"
# The container app replaces itself when updating, so it must run outside the App Sandbox.
# Re-sign only the outer app with sandbox off (works with every Xcode project format);
# the Safari extension inside keeps its own sandboxed signature.
IDENTITY="$(codesign -dvv "$APP_PATH" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
IDENTITY="${IDENTITY:--}"
ENT="$OUT/app.entitlements.plist"
codesign -d --entitlements - --xml "$APP_PATH" > "$ENT" 2>/dev/null || true
if [ ! -s "$ENT" ]; then
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$ENT"
fi
# PlistBuddy, not plutil: plutil treats the dots in the key as a nested path.
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$ENT" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool false" "$ENT"
codesign --force --sign "$IDENTITY" --entitlements "$ENT" --timestamp=none "$APP_PATH"
echo "App re-signed without sandbox using identity: $IDENTITY"

codesign --verify --deep --strict "$APP_PATH"
echo "Built and signature-verified: $APP_PATH"
echo "Run it once, then enable Aegis in Safari ▸ Settings ▸ Extensions."
