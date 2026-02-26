#!/usr/bin/env bash
set -euo pipefail

PLUGIN="$HOME/.config/hypr/plugins/split-monitor-workspaces.so"

if [ -f "$PLUGIN" ]; then
    for _ in $(seq 1 40); do
        if hyprctl plugin list 2>/dev/null | grep -q 'split-monitor-workspaces'; then
            break
        fi
        hyprctl plugin load "$PLUGIN" >/dev/null 2>&1 || true
        sleep 0.1
    done
fi

"$HOME/.config/hypr/scripts/split-ws-setup.sh" || true
