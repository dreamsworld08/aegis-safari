#!/usr/bin/env bash
# Build the Aegis Safari app + extension for Apple Silicon (arm64). Requires macOS with Xcode 15+.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Aegis"
# Must stay the same across releases: the in-app updater only accepts the same bundle id.
BUNDLE_ID="${BUNDLE_ID:-dev.aegis.Aegis}"
EXT_BUNDLE_ID="$BUNDLE_ID.Extension"
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
ORIG_JS="$(find "$OUT" -name Script.js -not -path '*Extension*' | head -1)"
[ -n "$ORIG_JS" ] || { echo "error: generated Script.js not found" >&2; exit 1; }
ASSET_DIR="$(dirname "$ORIG_JS")"
# In the built app, Script.js/Style.css sit in Contents/Resources; a localized Main.html
# (in Base.lproj) must reach them with "../".
case "$MAIN_DIR" in *.lproj) ASSETS="../" ;; *) ASSETS="" ;; esac
sed "s#__ASSETS__#$ASSETS#g" native/app/Main.html > "$MAIN_HTML"
cp native/app/Script.js native/app/Style.css "$ASSET_DIR/"

PROJ="$(find "$OUT" -maxdepth 2 -name '*.xcodeproj' | head -1)"
[ -n "$PROJ" ] || { echo "error: no .xcodeproj in $OUT" >&2; find "$OUT" -maxdepth 3 >&2; exit 1; }
# Xcode versions' converters name the targets' bundle ids differently. Normalise them to
# app=$BUNDLE_ID and extension=$BUNDLE_ID.Extension (signed builds require that prefix).
target_id() {
  xcodebuild -project "$PROJ" -target "$1" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}'
}
replace_id() { # $1 old id, $2 new id; whole-id matches only
  [ -n "$1" ] && [ "$1" != "$2" ] || return 0
  while IFS= read -r -d '' f; do
    perl -pi -e "s/(?<![\w.-])\Q$1\E(?![\w.-])/$2/g" "$f"
  done < <(grep -rIl --null -F "$1" "$PROJ" "$(dirname "$PROJ")/$APP" "$(dirname "$PROJ")/$APP Extension" 2>/dev/null || true)
}
APP_ID="$(target_id "$APP")"; EXT_ID="$(target_id "$APP Extension")"
echo "Generated bundle ids: app=$APP_ID extension=$EXT_ID"
replace_id "$EXT_ID" "$EXT_BUNDLE_ID"
replace_id "$APP_ID" "$BUNDLE_ID"
APP_ID="$(target_id "$APP")"; EXT_ID="$(target_id "$APP Extension")"
echo "Using bundle ids: app=$APP_ID extension=$EXT_ID"
if [ "$APP_ID" != "$BUNDLE_ID" ] || [ "$EXT_ID" != "$EXT_BUNDLE_ID" ]; then
  echo "error: could not normalise bundle ids. Matching project lines:" >&2
  grep -rIn -i "bundle_identifier\|aegis" "$PROJ" | head -20 >&2
  exit 1
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

# The app window must find its script and stylesheet, or it shows a dead page.
RES="$APP_PATH/Contents/Resources"
BUILT_MAIN="$(find "$RES" -name Main.html | head -1)"
for a in Script.js Style.css; do
  [ -f "$(dirname "$BUILT_MAIN")/$ASSETS$a" ] || { echo "error: app window asset $a missing next to $BUILT_MAIN" >&2; exit 1; }
done
grep -q "__ASSETS__" "$BUILT_MAIN" && { echo "error: unreplaced placeholder in Main.html" >&2; exit 1; }

codesign --verify --deep --strict "$APP_PATH"
echo "Built and signature-verified: $APP_PATH"
echo "Run it once, then enable Aegis in Safari ▸ Settings ▸ Extensions."
