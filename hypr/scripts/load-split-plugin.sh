#!/usr/bin/env bash
set -euo pipefail

PLUGIN="$HOME/.config/hypr/plugins/split-monitor-workspaces.so"

if [ -f "$PLUGIN" ]; then
    hyprctl plugin load "$PLUGIN" >/dev/null 2>&1 || true
fi

"$HOME/.config/hypr/scripts/split-ws-setup.sh" || true
