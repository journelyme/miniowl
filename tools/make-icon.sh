#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# make-icon.sh — generate miniowl-bundle/AppIcon.icns from scratch.
#
# Renders a 1024×1024 master PNG via tools/make-icon.swift, then asks
# `sips` to resample it to all the macOS icon sizes and `iconutil` to
# pack the iconset into a single .icns file.
#
# Run from anywhere — paths are resolved relative to the script's
# location, not the caller's CWD.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")/.."

MASTER="build/icon-master-1024.png"
SET="build/AppIcon.iconset"
OUT="miniowl-bundle/AppIcon.icns"

mkdir -p build "$(dirname "$OUT")"

echo "1. rendering master 1024×1024 PNG..."
swift tools/make-icon.swift "$MASTER"

echo ""
echo "2. resampling to all standard macOS icon sizes..."
rm -rf "$SET"
mkdir -p "$SET"
sips -z 16   16   "$MASTER" --out "$SET/icon_16x16.png"     >/dev/null
sips -z 32   32   "$MASTER" --out "$SET/icon_16x16@2x.png"  >/dev/null
sips -z 32   32   "$MASTER" --out "$SET/icon_32x32.png"     >/dev/null
sips -z 64   64   "$MASTER" --out "$SET/icon_32x32@2x.png"  >/dev/null
sips -z 128  128  "$MASTER" --out "$SET/icon_128x128.png"   >/dev/null
sips -z 256  256  "$MASTER" --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$MASTER" --out "$SET/icon_256x256.png"   >/dev/null
sips -z 512  512  "$MASTER" --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$MASTER" --out "$SET/icon_512x512.png"   >/dev/null
cp "$MASTER" "$SET/icon_512x512@2x.png"

echo ""
echo "3. packing into .icns..."
iconutil -c icns "$SET" -o "$OUT"

# Cleanup intermediates
rm -rf "$SET"

echo ""
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
