#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-show}"
MAX_LOCAL=10
MIN_LOCAL=1

if ! command -v hyprctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

STATE_DIR="$HOME/.config/hypr/state"
STATE_FILE="$STATE_DIR/split-limits.json"
LOCK_FILE="$STATE_DIR/split-limits.lock"
mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] || printf '{}\n' > "$STATE_FILE"
exec 9>"$LOCK_FILE"
flock -x 9

default_limit_for_index() {
    local idx="$1"
    case "$idx" in
        0) echo 2 ;;
        1) echo 3 ;;
        *) echo 4 ;;
    esac
}

workspace_count() {
    local c
    c="$(hyprctl getoption plugin:split-monitor-workspaces:count 2>/dev/null | awk '/int:/ {print $2; exit}')"
    if [[ -z "$c" || ! "$c" =~ ^[0-9]+$ || "$c" -lt 1 ]]; then
        c=10
    fi
    echo "$c"
}

clamp_monitor_to_limit() {
    local mon="$1"
    local lim="$2"
    local wsid cnt local_idx

    wsid="$(hyprctl monitors -j | jq -r --arg mn "$mon" '.[] | select(.name==$mn) | .activeWorkspace.id' 2>/dev/null || true)"
    if [[ -z "$wsid" || ! "$wsid" =~ ^[0-9]+$ ]]; then
        return
    fi

    cnt="$(workspace_count)"
    local_idx=$(( ((wsid - 1) % cnt) + 1 ))
    if [ "$local_idx" -gt "$lim" ]; then
        hyprctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
        hyprctl dispatch split-workspace "$lim" >/dev/null 2>&1 || true
    fi
}

get_limit() {
    local mon="$1"
    local idx="$2"
    local v
    v="$(jq -r --arg m "$mon" '.[$m] // empty' "$STATE_FILE" 2>/dev/null || true)"
    if [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]]; then
        v="$(default_limit_for_index "$idx")"
    fi
    if [ "$v" -lt "$MIN_LOCAL" ]; then v="$MIN_LOCAL"; fi
    if [ "$v" -gt "$MAX_LOCAL" ]; then v="$MAX_LOCAL"; fi
    echo "$v"
}

set_limit() {
    local mon="$1"
    local v="$2"
    local tmp
    tmp="$(mktemp)"
    jq --arg m "$mon" --argjson v "$v" '.[$m]=$v' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

MON_JSON="$(hyprctl monitors -j 2>/dev/null || echo '[]')"
MON_COUNT="$(echo "$MON_JSON" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$MON_COUNT" -lt 1 ]; then
    exit 0
fi

FOCUS_MONITOR="$(echo "$MON_JSON" | jq -r 'sort_by(.x,.y) | map(select(.focused == true)) | if length > 0 then .[0].name else .[0].name end')"
FOCUS_INDEX="$(echo "$MON_JSON" | jq -r --arg m "$FOCUS_MONITOR" 'sort_by(.x,.y) | to_entries | map(select(.value.name == $m)) | if length > 0 then .[0].key else 0 end')"

CURRENT="$(get_limit "$FOCUS_MONITOR" "$FOCUS_INDEX")"

case "$MODE" in
    inc)
        NEW=$((CURRENT + 1))
        if [ "$NEW" -gt "$MAX_LOCAL" ]; then NEW="$MAX_LOCAL"; fi
        set_limit "$FOCUS_MONITOR" "$NEW"
        hyprctl notify -1 1800 "rgb(88ccff)" "$FOCUS_MONITOR: limit ws -> $NEW" >/dev/null 2>&1 || true
        ;;
    dec)
        NEW=$((CURRENT - 1))
        if [ "$NEW" -lt "$MIN_LOCAL" ]; then NEW="$MIN_LOCAL"; fi
        set_limit "$FOCUS_MONITOR" "$NEW"
        clamp_monitor_to_limit "$FOCUS_MONITOR" "$NEW"
        hyprctl notify -1 1800 "rgb(88ccff)" "$FOCUS_MONITOR: limit ws -> $NEW" >/dev/null 2>&1 || true
        ;;
    reset-monitor)
        tmp="$(mktemp)"
        jq --arg m "$FOCUS_MONITOR" 'del(.[$m])' "$STATE_FILE" > "$tmp"
        mv "$tmp" "$STATE_FILE"
        NEW="$(get_limit "$FOCUS_MONITOR" "$FOCUS_INDEX")"
        clamp_monitor_to_limit "$FOCUS_MONITOR" "$NEW"
        hyprctl notify -1 1800 "rgb(88ccff)" "$FOCUS_MONITOR: reset limit -> $NEW" >/dev/null 2>&1 || true
        ;;
    reset-all)
        printf '{}\n' > "$STATE_FILE"
        while IFS=$'\t' read -r idx mon focused; do
            [ -z "$mon" ] && continue
            clamp_monitor_to_limit "$mon" "$(default_limit_for_index "$idx")"
        done < <(echo "$MON_JSON" | jq -r 'sort_by(.x,.y) | to_entries[] | [.key, .value.name, .value.focused] | @tsv')
        hyprctl notify -1 2000 "rgb(88ccff)" "split limits: reset global" >/dev/null 2>&1 || true
        ;;
    show)
        ;;
    *)
        exit 0
        ;;
esac

# Mostrar estado actual de todos los monitores.
MON_JSON="$(hyprctl monitors -j 2>/dev/null || echo '[]')"
DETAIL=""
while IFS=$'\t' read -r idx mon focused; do
    [ -z "$mon" ] && continue
    lim="$(get_limit "$mon" "$idx")"
    mark=""
    if [ "$focused" = "true" ]; then mark="*"; fi
    DETAIL+="M$((idx + 1)):${mon}=${lim}${mark} "
done < <(echo "$MON_JSON" | jq -r 'sort_by(.x,.y) | to_entries[] | [.key, .value.name, .value.focused] | @tsv')

hyprctl notify -1 2500 "rgb(66ddaa)" "split limits: $DETAIL" >/dev/null 2>&1 || true
