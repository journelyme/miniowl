#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# setup-notary.sh — one-time setup for the notarization credentials.
#
# Stores your Apple ID + Team ID + app-specific password as a profile
# in the macOS keychain. After this, `make-dmg.sh` (and any other
# notarytool invocation) can reference the profile by name without
# touching the password.
#
# Prerequisites:
#   1. A paid Apple Developer Program membership (you already have one)
#   2. A "Developer ID Application" certificate in your keychain
#      (run `security find-identity -v -p codesigning | grep "Developer ID"`)
#   3. An APP-SPECIFIC password from https://appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords → Generate)
#      DO NOT use your real Apple ID password — Apple won't accept it.
#
# Usage:
#   ./tools/setup-notary.sh <apple-id-email> [team-id]
#
# Example (defaults to JOURNELY LLC):
#   ./tools/setup-notary.sh hello@journely.me
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

PROFILE_NAME="${MINIOWL_NOTARY_PROFILE:-miniowl-notary}"
APPLE_ID="${1:-}"
TEAM_ID="${2:-APGC7K5255}"  # JOURNELY LLC default

if [[ -z "$APPLE_ID" ]]; then
  cat <<EOF
usage: $0 <apple-id-email> [team-id]

  apple-id-email   the email you sign in to developer.apple.com with
  team-id          defaults to APGC7K5255 (JOURNELY LLC)

what this does:
  runs \`xcrun notarytool store-credentials\` to save your Apple ID +
  team ID + app-specific password into your macOS login keychain
  under the profile name "$PROFILE_NAME". After this, you never type
  the password again.

before running, get an APP-SPECIFIC password from
  https://appleid.apple.com -> Sign-In and Security ->
  App-Specific Passwords -> Generate

then run:
  $0 hello@journely.me

you'll be prompted for the app-specific password — paste the
xxxx-xxxx-xxxx-xxxx string from Apple. nothing is written to disk
in plaintext; the keychain holds the credential after this.
EOF
  exit 1
fi

echo "storing notarization credentials for:"
echo "  Apple ID:  $APPLE_ID"
echo "  Team ID:   $TEAM_ID"
echo "  Profile:   $PROFILE_NAME"
echo ""
echo "you will be prompted for the app-specific password next."
echo "(get it from https://appleid.apple.com → App-Specific Passwords)"
echo ""

xcrun notarytool store-credentials "$PROFILE_NAME" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID"

echo ""
echo "done. test by listing past notarization runs (will be empty for first time):"
echo "  xcrun notarytool history --keychain-profile $PROFILE_NAME"
