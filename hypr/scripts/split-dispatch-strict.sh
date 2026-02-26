#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
REQ_RAW="${2:-}"

if [[ ! "$REQ_RAW" =~ ^[1-9][0-9]*$ ]]; then
    exit 0
fi

if ! command -v hyprctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

REQ="$REQ_RAW"
MON_JSON="$(hyprctl monitors -j 2>/dev/null || echo '[]')"
MON_COUNT="$(echo "$MON_JSON" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$MON_COUNT" -lt 1 ]; then
    exit 0
fi

# Orden físico estable: izquierda->derecha, arriba->abajo.
FOCUSED_INDEX="$(echo "$MON_JSON" | jq -r '
  sort_by(.x, .y)
  | to_entries
  | map(select(.value.focused == true))
  | if length > 0 then .[0].key else 0 end
')"

# Límite por monitor: M1=2, M2=3, M3=4, resto=4.
case "$FOCUSED_INDEX" in
  0) LIMIT=2 ;;
  1) LIMIT=3 ;;
  *) LIMIT=4 ;;
esac

TARGET="$REQ"
if [ "$TARGET" -gt "$LIMIT" ]; then
    TARGET="$LIMIT"
    hyprctl notify -1 1200 "rgb(ffcc66)" "Monitor $((FOCUSED_INDEX + 1)): max ws=$LIMIT" >/dev/null 2>&1 || true
fi

case "$MODE" in
  switch)
    hyprctl dispatch split-workspace "$TARGET" >/dev/null 2>&1 || true
    ;;
  move)
    hyprctl dispatch split-movetoworkspacesilent "$TARGET" >/dev/null 2>&1 || true
    ;;
  *)
    exit 0
    ;;
esac
