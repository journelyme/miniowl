#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# make-dmg.sh — build, sign, package, notarize, and staple a
# distributable .dmg of miniowl.app.
#
# Output: release/miniowl-<version>.dmg, signed by JOURNELY LLC's
# Developer ID Application certificate and notarized by Apple, with
# the notarization ticket stapled directly into the .dmg so users
# can run it offline without Gatekeeper warnings.
#
# Prerequisites:
#   1. A Developer ID Application certificate in your keychain
#      (see README — Cutting a release)
#   2. Notarization credentials stored in keychain via
#      ./tools/setup-notary.sh hello@journely.me
#   3. Network access (Apple's notary service is online)
#
# The version is read from miniowl-bundle/Info.plist
# (CFBundleShortVersionString). To bump the version, edit that key
# and re-run.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${MINIOWL_NOTARY_PROFILE:-miniowl-notary}"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - miniowl-bundle/Info.plist)
APP="build/miniowl.app"
RELEASE_DIR="release"
DMG="$RELEASE_DIR/miniowl-${VERSION}.dmg"
STAGING="build/dmg-staging"
VOLUME_NAME="miniowl ${VERSION}"

echo "─────────────────────────────────────"
echo " miniowl release pipeline"
echo "─────────────────────────────────────"
echo " version:        $VERSION"
echo " volume name:    $VOLUME_NAME"
echo " output:         $DMG"
echo " notary profile: $NOTARY_PROFILE"
echo "─────────────────────────────────────"
echo ""

# ── Step 1: build + sign the .app via the existing pipeline ─────────
echo "[1/8] building signed .app via build-app.sh..."
./scripts/build-app.sh

# Pull the signing identity out of the freshly-built .app so we sign
# the .dmg with the SAME identity (which is required for notarization).
SIGN_IDENTITY=$(codesign -dvv "$APP" 2>&1 \
  | awk -F'Authority=' '/Authority=Developer ID Application/ {print $2; exit}')

if [[ -z "$SIGN_IDENTITY" ]]; then
  cat <<EOF
error: the built .app is NOT signed with a Developer ID Application
       certificate. Notarization requires Developer ID. Currently the
       .app is signed with:

$(codesign -dvv "$APP" 2>&1 | grep -E "Authority|Signature" | head -3 | sed 's/^/    /')

       To fix: install a "Developer ID Application: ... (TEAMID)"
       cert in your login keychain. See README — "Cutting a release".
EOF
  exit 1
fi
echo "      signed by: $SIGN_IDENTITY"
echo ""

# ── Step 2: sanity-check the .app's hardened runtime + entitlements ─
echo "[2/8] verifying .app is notarization-ready..."
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/      /' || {
  echo "error: codesign --verify failed for $APP"
  exit 1
}
# Hardened Runtime is required for notarization
if ! codesign -dvv "$APP" 2>&1 | grep -q "flags=0x10000"; then
  # 0x10000 = runtime flag set
  if ! codesign -dvv "$APP" 2>&1 | grep -qE "runtime"; then
    echo "warning: .app may not have Hardened Runtime enabled — notarization may fail"
  fi
fi
echo ""

# ── Step 3: stage a folder with the .app + Applications symlink ─────
echo "[3/8] staging dmg contents..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
echo "      $STAGING:"
ls -la "$STAGING/" | sed 's/^/        /'
echo ""

# ── Step 4: build the .dmg ───────────────────────────────────────────
echo "[4/8] creating .dmg with hdiutil..."
mkdir -p "$RELEASE_DIR"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG" \
  | sed 's/^/      /'
echo ""

# ── Step 5: sign the .dmg itself with the same Developer ID ─────────
echo "[5/8] signing .dmg with $SIGN_IDENTITY..."
codesign --force --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify "$DMG"
echo "      ok"
echo ""

# ── Step 6: submit to Apple's notary service ────────────────────────
echo "[6/8] submitting to Apple notary (typically 30s–2min)..."
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format plist > /tmp/miniowl-notary.plist 2>&1 || {
  echo "error: notarytool submit failed"
  cat /tmp/miniowl-notary.plist
  exit 1
}
NOTARY_STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" /tmp/miniowl-notary.plist 2>/dev/null || echo "unknown")
NOTARY_ID=$(/usr/libexec/PlistBuddy -c "Print :id" /tmp/miniowl-notary.plist 2>/dev/null || echo "unknown")
echo "      submission id: $NOTARY_ID"
echo "      status:        $NOTARY_STATUS"

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  echo ""
  echo "notarization did not return Accepted. Fetching the log..."
  xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" || true
  exit 1
fi
echo ""

# ── Step 7: staple the notarization ticket onto the .dmg ────────────
echo "[7/8] stapling ticket onto .dmg..."
xcrun stapler staple "$DMG" 2>&1 | sed 's/^/      /'
echo ""

# ── Step 8: final verification — Gatekeeper accept the .dmg? ────────
echo "[8/8] verifying with spctl (Gatekeeper)..."
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/      /'
echo ""

# ── Cleanup ─────────────────────────────────────────────────────────
rm -rf "$STAGING"

echo "─────────────────────────────────────"
echo " ✓ release built and notarized"
echo "─────────────────────────────────────"
ls -lh "$DMG"
echo ""
echo "next steps:"
echo "  1. test the .dmg locally:  open $DMG"
echo "  2. cut a github release:    gh release create v$VERSION $DMG"
echo "                               (or via the web UI)"
