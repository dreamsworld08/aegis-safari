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
MAIN_DIR="$(dirname "$(find "$OUT" -name Main.html -not -path '*Extension*' | head -1)")"
cp native/app/Main.html native/app/Script.js native/app/Style.css "$MAIN_DIR/"

# The container app replaces itself when updating, so it runs outside the App Sandbox.
# The Safari extension itself stays sandboxed.
python3 - "$OUT" "$BUNDLE_ID" <<'PY'
import glob, plistlib, re, sys
out, bid = sys.argv[1], sys.argv[2]
proj = glob.glob(f"{out}/**/project.pbxproj", recursive=True)[0]
s = open(proj).read()
def fix(m):
    b = m.group(0)
    if re.search(r'PRODUCT_BUNDLE_IDENTIFIER = "?%s"?;' % re.escape(bid), b):
        b = b.replace("ENABLE_APP_SANDBOX = YES", "ENABLE_APP_SANDBOX = NO")
    return b
open(proj, "w").write(re.sub(r"buildSettings = \{.*?\n\t\t\t\};", fix, s, flags=re.S))
for f in glob.glob(f"{out}/**/*.entitlements", recursive=True):
    if "Extension" in f:
        continue
    with open(f, "rb") as fh:
        d = plistlib.load(fh)
    d["com.apple.security.app-sandbox"] = False
    with open(f, "wb") as fh:
        plistlib.dump(d, fh)
    print("App sandbox off:", f)
PY

PROJ="$(find "$OUT" -maxdepth 2 -name '*.xcodeproj' | head -1)"
xcodebuild -project "$PROJ" -scheme "$APP" -configuration Release \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  -derivedDataPath "$OUT/DerivedData" ${SIGN_ARGS:-CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO} build

APP_PATH="$(find "$OUT/DerivedData" -name "$APP.app" -type d | head -1)"
codesign --verify --deep --strict "$APP_PATH"
echo "Built and signature-verified: $APP_PATH"
echo "Run it once, then enable Aegis in Safari ▸ Settings ▸ Extensions."
