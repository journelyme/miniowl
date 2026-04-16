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
EXCLUDE_BASENAMES=(
  "ForbiddenImports.swift"
  # v2.0 (opt-in) categorization: URLSession is allowed in EXACTLY
  # one file so the audit surface stays minimal. Anything else that
  # imports URLSession will fail this script.
  "CategorizationClient.swift"
)

# URLSession is the only banned symbol with a per-file allowlist.
URL_SESSION_ALLOWLIST="CategorizationClient.swift"

failed=0
for sym in "${BANNED[@]}"; do
  exclude_args=()
  for f in "${EXCLUDE_BASENAMES[@]}"; do
    # URLSession allowlist applies only to URLSession; other banned
    # symbols still fail even in CategorizationClient.swift.
    if [[ "$f" == "$URL_SESSION_ALLOWLIST" && "$sym" != "URLSession" && "$sym" != "URLSessionDataTask" ]]; then
      continue
    fi
    exclude_args+=("--exclude=$f")
  done

  matches=$(grep -rl \
              --include="*.swift" \
              "${exclude_args[@]}" \
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
