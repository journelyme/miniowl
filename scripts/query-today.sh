#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# query-today.sh — quick ad-hoc query of today's miniowl data.
#
# Prints a sorted "top apps by active time" table + AFK total + the
# day's launch/sleep/wake markers. No dependencies beyond `jq` and
# awk, both already on macOS.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

DATA="$HOME/Library/Application Support/miniowl"
TODAY=$(date +%F)
FILE="$DATA/$TODAY.mow"

if [[ ! -f "$FILE" ]]; then
  echo "no data for $TODAY at $FILE"
  exit 1
fi

echo "miniowl — $TODAY"
echo "─────────────────────────────────────"

echo ""
echo "Top apps by active time"
echo ""
jq -r 'select(.t=="w") | "\(.e-.s)\t\(.n)"' "$FILE" \
  | awk -F'\t' '{sum[$2]+=$1} END {for(k in sum) printf "%6.1fm  %s\n", sum[k]/60000, k}' \
  | sort -rn \
  | head -20

echo ""
AFK_MS=$(jq -r 'select(.t=="a") | .e - .s' "$FILE" | awk '{s+=$1} END {print s+0}')
printf "AFK:         %6.1f min\n" "$(awk "BEGIN{print $AFK_MS/60000}")"

echo ""
echo "System markers"
jq -r 'select(.t=="s") | "\(.s)\t\(.k)"' "$FILE" | while IFS=$'\t' read -r ts kind; do
  human=$(date -r "$((ts / 1000))" "+%H:%M:%S")
  printf "  %s  %s\n" "$human" "$kind"
done
