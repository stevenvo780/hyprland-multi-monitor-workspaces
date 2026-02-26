#!/usr/bin/env bash
set -euo pipefail

PLUGIN_REPO="https://github.com/Duckonaut/split-monitor-workspaces"
PLUGIN_COMMIT="a03a32c6e0f64c05c093ced864a326b4ab58eabf"  # pin for Hyprland v0.41.2
SRC_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/hypr-plugin-src/split-monitor-workspaces"
OUT_DIR="${1:-$HOME/.config/hypr/plugins}"

mkdir -p "$(dirname "$SRC_DIR")" "$OUT_DIR"

if [ ! -d "$SRC_DIR/.git" ]; then
  git clone "$PLUGIN_REPO" "$SRC_DIR"
fi

cd "$SRC_DIR"
git fetch --all --tags --prune
git checkout "$PLUGIN_COMMIT"

make clean || true
# Override to avoid makefile probing hyprctl runtime flags when no session is active.
make all BUILT_WITH_NOXWAYLAND=

cp -f split-monitor-workspaces.so "$OUT_DIR/split-monitor-workspaces.so"
sha256sum "$OUT_DIR/split-monitor-workspaces.so"
