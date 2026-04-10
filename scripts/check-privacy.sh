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

# Exclude the manifest file itself — it names the banned symbols on
# purpose. We use grep's built-in --exclude (matched against the
# basename) instead of post-filtering by path so this works the same
# on macOS BSD grep, GNU grep on Linux, and the GitHub Actions runner
# (which sometimes emits paths with double slashes that defeat string
# matching against the full path).
EXCLUDE_BASENAME="ForbiddenImports.swift"

failed=0
for sym in "${BANNED[@]}"; do
  matches=$(grep -rl \
              --include="*.swift" \
              --exclude="$EXCLUDE_BASENAME" \
              -- "$sym" Sources 2>/dev/null || true)
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
