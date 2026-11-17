#!/usr/bin/env bash
# Re-sign a built Aegis.app with an Apple Development certificate (free Apple ID "Personal Team" works).
# Inputs (GitHub Actions secrets): MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD
set -euo pipefail
APP="$1"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
KC="$TMP/aegis-signing.keychain-db"
KCPASS="$(uuidgen)"

printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode > "$TMP/cert.p12"
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/cert.p12" -k "$KC" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -f "$TMP/cert.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')

ID="$(security find-identity -v -p codesigning "$KC" | awk '/"Apple Development|"Developer ID Application/ {print $2; exit}')"
[ -n "$ID" ] || { echo "No Apple Development / Developer ID identity found in the certificate"; exit 1; }

# Sign inside-out, keeping each bundle's existing entitlements (extension stays sandboxed).
sign() {
  local target="$1" ent="$TMP/$(basename "$1").entitlements.plist"
  codesign -d --entitlements - --xml "$target" > "$ent"
  codesign --force --sign "$ID" --keychain "$KC" --entitlements "$ent" --timestamp=none "$target"
}
for x in "$APP"/Contents/PlugIns/*.appex; do sign "$x"; done
sign "$APP"

codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier)=" | head -3
security delete-keychain "$KC"
