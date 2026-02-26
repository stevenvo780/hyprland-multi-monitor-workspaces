#!/usr/bin/env bash
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST_ROOT="$HOME/.config/hypr"

mkdir -p "$DST_ROOT/conf.d" "$DST_ROOT/scripts" "$DST_ROOT/plugins"

cp -f "$SRC_ROOT/hypr/hyprland.conf" "$DST_ROOT/hyprland.conf"
cp -f "$SRC_ROOT/hypr/conf.d/99-split-monitor-workspaces.conf" "$DST_ROOT/conf.d/99-split-monitor-workspaces.conf"
cp -f "$SRC_ROOT/hypr/scripts/load-split-plugin.sh" "$DST_ROOT/scripts/load-split-plugin.sh"
cp -f "$SRC_ROOT/hypr/scripts/split-dispatch-strict.sh" "$DST_ROOT/scripts/split-dispatch-strict.sh"
cp -f "$SRC_ROOT/hypr/scripts/split-limit-adjust.sh" "$DST_ROOT/scripts/split-limit-adjust.sh"
cp -f "$SRC_ROOT/hypr/scripts/split-ws-setup.sh" "$DST_ROOT/scripts/split-ws-setup.sh"
chmod +x \
  "$DST_ROOT/scripts/load-split-plugin.sh" \
  "$DST_ROOT/scripts/split-dispatch-strict.sh" \
  "$DST_ROOT/scripts/split-limit-adjust.sh" \
  "$DST_ROOT/scripts/split-ws-setup.sh"

echo "Hypr config deployed to $DST_ROOT"
