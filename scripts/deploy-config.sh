#!/usr/bin/env bash
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST_ROOT="$HOME/.config/hypr"
BACKUP_ROOT="$DST_ROOT/backups"
HOME_REAL="$(realpath -m -- "$HOME")"
BACKUP_REAL="$(realpath -m -- "$BACKUP_ROOT")"

FILES=(
  hyprland.conf
  conf.d/99-split-monitor-workspaces.conf
  scripts/load-split-plugin.sh
  scripts/split-dispatch-strict.sh
  scripts/split-limit-adjust.sh
  scripts/split-ws-setup.sh
)
EXISTING_FILES=()

# Validate resolved paths under HOME and reject aliases to recognized backups.
# Check before creating directories or backups; allow ordinary internal symlinks.
check_path() {
  local resolved
  resolved="$(realpath -m -- "$1")"
  if [[ "$resolved" != "$HOME_REAL" && "$resolved" != "$HOME_REAL/"* ]]; then
    printf 'Refusing path outside HOME: %s\n' "$1" >&2
    exit 1
  fi
  if [[ "$1" != "$BACKUP_ROOT" && ( "$resolved" == "$BACKUP_REAL" || "$resolved" == "$BACKUP_REAL/"* ) ]]; then
    printf 'Refusing deployment into backups: %s\n' "$1" >&2
    exit 1
  fi
}

for path in "$DST_ROOT" "$DST_ROOT/conf.d" "$DST_ROOT/scripts" "$DST_ROOT/plugins" "$BACKUP_ROOT"; do
  check_path "$path"
done
for file in "${FILES[@]}"; do
  destination="$DST_ROOT/$file"
  check_path "$destination"
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ ! -f "$destination" ]]; then
      printf 'Cannot back up non-regular destination: %s\n' "$destination" >&2
      exit 1
    fi
    # A hard link has a different path but can still alias a prior preimage.
    for previous_backup in "$BACKUP_ROOT"/deploy-config.*; do
      [[ -d "$previous_backup" ]] || continue
      for backup_file in "${FILES[@]}"; do
        if [[ "$destination" -ef "$previous_backup/$backup_file" ]]; then
          printf 'Refusing destination linked to a backup: %s\n' "$destination" >&2
          exit 1
        fi
      done
    done
    EXISTING_FILES+=("$file")
  fi
done

mkdir -p "$DST_ROOT/conf.d" "$DST_ROOT/scripts" "$DST_ROOT/plugins"

# A fresh directory prevents collisions on repeated runs. Complete every
# preimage before the first deployment copy; any mkdir/mktemp/cp failure exits
# under set -e, retaining partial backups and leaving all destinations intact.
if (( ${#EXISTING_FILES[@]} > 0 )); then
  mkdir -p -- "$BACKUP_ROOT"
  BACKUP_DIR="$(mktemp -d -- "$BACKUP_ROOT/deploy-config.XXXXXXXX")"
  printf 'Backing up existing Hypr config to %s\n' "$BACKUP_DIR"
  for file in "${EXISTING_FILES[@]}"; do
    mkdir -p -- "$BACKUP_DIR/$(dirname -- "$file")"
    # Dereference file symlinks so a later write cannot mutate the preimage.
    cp -pL -- "$DST_ROOT/$file" "$BACKUP_DIR/$file"
  done
fi

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
