#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# check-privacy.sh — fail the build if any banned macOS API appears
# in the Swift source tree. See Sources/miniowl/Privacy/ForbiddenImports.swift
# for the list and rationale.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")/.."

BANNED=(
  "NSPasteboard"
  "CGEventTap"
  "addGlobalMonitorForEvents"
  "CGWindowListCreateImage"
  "CGDisplayStream"
  "ScreenCaptureKit"
  "URLSession"
  "URLSessionDataTask"
  "Network.framework"
)

# Exclude the manifest file itself — it names the banned symbols on purpose.
EXCLUDE="Sources/miniowl/Privacy/ForbiddenImports.swift"

failed=0
for sym in "${BANNED[@]}"; do
  # Find any .swift file (excluding the manifest) that contains the symbol.
  matches=$(grep -rl --include="*.swift" -- "$sym" Sources/ 2>/dev/null \
            | grep -v -F "$EXCLUDE" || true)
  if [[ -n "$matches" ]]; then
    echo "PRIVACY VIOLATION: banned symbol '$sym' found in:"
    echo "$matches" | sed 's/^/    /'
    failed=1
  fi
done

if [[ $failed -eq 1 ]]; then
  echo ""
  echo "miniowl's privacy contract forbids these APIs. See"
  echo "Sources/miniowl/Privacy/ForbiddenImports.swift for the rationale."
  exit 1
fi

echo "privacy check: clean"
