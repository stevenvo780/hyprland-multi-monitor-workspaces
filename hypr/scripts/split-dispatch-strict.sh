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

STATE_DIR="$HOME/.config/hypr/state"
STATE_FILE="$STATE_DIR/split-limits.json"
MAX_LOCAL=10
mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] || printf '{}\n' > "$STATE_FILE"

default_limit_for_index() {
    local idx="$1"
    case "$idx" in
        0) echo 2 ;;
        1) echo 3 ;;
        *) echo 4 ;;
    esac
}

MON_JSON="$(hyprctl monitors -j 2>/dev/null || echo '[]')"
MON_COUNT="$(echo "$MON_JSON" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$MON_COUNT" -lt 1 ]; then
    exit 0
fi

FOCUS_MONITOR="$(echo "$MON_JSON" | jq -r 'sort_by(.x,.y) | map(select(.focused == true)) | if length > 0 then .[0].name else .[0].name end')"
FOCUS_INDEX="$(echo "$MON_JSON" | jq -r --arg m "$FOCUS_MONITOR" 'sort_by(.x,.y) | to_entries | map(select(.value.name == $m)) | if length > 0 then .[0].key else 0 end')"

REQ="$REQ_RAW"
LIMIT="$(jq -r --arg m "$FOCUS_MONITOR" '.[$m] // empty' "$STATE_FILE" 2>/dev/null || true)"
if [[ -z "$LIMIT" || ! "$LIMIT" =~ ^[0-9]+$ ]]; then
    LIMIT="$(default_limit_for_index "$FOCUS_INDEX")"
fi
if [ "$LIMIT" -lt 1 ]; then LIMIT=1; fi
if [ "$LIMIT" -gt "$MAX_LOCAL" ]; then LIMIT="$MAX_LOCAL"; fi

TARGET="$REQ"
if [ "$TARGET" -gt "$LIMIT" ]; then
    TARGET="$LIMIT"
    hyprctl notify -1 900 "rgb(ffcc66)" "${FOCUS_MONITOR}: max ws=$LIMIT" >/dev/null 2>&1 || true
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
