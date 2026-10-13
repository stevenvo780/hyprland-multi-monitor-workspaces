#!/usr/bin/env bash
# Synthetic filesystem tests only. Keep fixtures, backups and per-run logs for review.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_CP="$(command -v cp)"
SYSTEM_PATH="$PATH"
TEST_ROOT="$(mktemp -d /tmp/deploy-config-backup.XXXXXXXX)"
export HOME="$TEST_ROOT/home with spaces"
mkdir -p -- "$HOME"
printf 'Synthetic HOME and retained evidence: %s\n' "$HOME"

FILES=(
    hyprland.conf
    conf.d/99-split-monitor-workspaces.conf
    scripts/load-split-plugin.sh
    scripts/split-dispatch-strict.sh
    scripts/split-limit-adjust.sh
    scripts/split-ws-setup.sh
)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
equal_files() {
    [[ -f "$1" && -f "$2" ]] || fail "missing file: $1 or $2"
    [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]] || fail "different bytes: $1 and $2"
}

new_case() {
    CASE_ROOT="$HOME/$1"
    CASE_HOME="$CASE_ROOT/home with spaces"
    DST="$CASE_HOME/.config/hypr"
    mkdir -p -- "$CASE_HOME"
    # Exercise a source path with spaces without making a second working checkout.
    ln -s -- "$REPO_ROOT" "$CASE_HOME/source with spaces"
    RUN=0
}

save_preimages() {
    PREIMAGES="$CASE_HOME/preimages/$1"
    local file
    for file in "${FILES[@]}"; do
        mkdir -p -- "$PREIMAGES/$(dirname -- "$file")"
        "$REAL_CP" -pL -- "$DST/$file" "$PREIMAGES/$file"
    done
}

seed_files() {
    local file
    for file in "${FILES[@]}"; do
        mkdir -p -- "$DST/$(dirname -- "$file")"
        printf 'SENTINEL %s %s\n\000binary preimage\n' "$1" "$file" > "$DST/$file"
    done
    save_preimages "$1"
}

run_deploy() {
    RUN=$((RUN + 1))
    local log="$CASE_HOME/run-$RUN"
    local -a command=(env -i HOME="$CASE_HOME" PATH="$SYSTEM_PATH" REAL_CP="$REAL_CP"
        TEST_SHIM="$CASE_HOME/shim.sh" TEST_DEPLOY="$CASE_HOME/source with spaces/scripts/deploy-config.sh"
        bash --noprofile --norc -c
        'if [[ -f "$TEST_SHIM" ]]; then source "$TEST_SHIM"; for name in cp mkdir mktemp; do if declare -F "$name" >/dev/null; then export -f "$name"; fi; done; fi; exec bash --noprofile --norc "$TEST_DEPLOY"')
    printf '%q ' "${command[@]}" > "$log.command"
    printf '\n' >> "$log.command"
    if "${command[@]}" > "$log.stdout" 2> "$log.stderr"; then
        DEPLOY_STATUS=0
    else
        DEPLOY_STATUS=$?
    fi
    printf '%s\n' "$DEPLOY_STATUS" > "$log.exit"
    printf 'deployment %s: exit %s\n' "$RUN" "$DEPLOY_STATUS"
}

expect_success() {
    [[ "$DEPLOY_STATUS" == 0 ]] || fail "deployment failed; see $CASE_HOME/run-$RUN.stderr"
}
expect_failure() { [[ "$DEPLOY_STATUS" != 0 ]] || fail 'deployment unexpectedly succeeded'; }

snapshots() {
    shopt -s nullglob
    SNAPSHOTS=("$DST/backups"/deploy-config.*)
}
check_snapshot() {
    local snapshot="$1" preimages="$2" file
    [[ -d "$snapshot" && ! -L "$snapshot" ]] || fail "not an independent snapshot: $snapshot"
    for file in "${FILES[@]}"; do
        [[ ! -L "$snapshot/$file" ]] || fail "backup follows a mutable symlink: $file"
        equal_files "$preimages/$file" "$snapshot/$file"
        [[ "$(stat -c '%a:%Y' -- "$preimages/$file")" == "$(stat -c '%a:%Y' -- "$snapshot/$file")" ]] || fail "backup mode/mtime changed: $file"
    done
}
check_unchanged() {
    local file
    for file in "${FILES[@]}"; do equal_files "$PREIMAGES/$file" "$DST/$file"; done
}
check_installed() {
    local file
    for file in "${FILES[@]}"; do equal_files "$REPO_ROOT/hypr/$file" "$DST/$file"; done
    for file in "${FILES[@]:2}"; do [[ -x "$DST/$file" ]] || fail "script is not executable: $file"; done
    [[ -d "$DST/plugins" ]] || fail 'plugin directory was not created'
}

six_files() {
    new_case six_files
    seed_files first
    mkdir -p -- "$DST/plugins"
    printf 'user plugin\n' > "$DST/plugins/custom.so"
    printf 'user config\n' > "$DST/user.conf"
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail "expected one complete snapshot, got ${#SNAPSHOTS[@]} (sentinels lost without backup)"
    check_snapshot "${SNAPSHOTS[0]}" "$PREIMAGES"
    check_installed
    [[ "$(cat "$DST/plugins/custom.so")" == 'user plugin' && "$(cat "$DST/user.conf")" == 'user config' ]] || fail 'unrelated user files changed'
}

clean_install() {
    new_case clean_install
    run_deploy; expect_success
    check_installed
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 0 ]] || fail 'clean install backed up nonexistent files'
}

partial_install() {
    new_case partial_install
    mkdir -p -- "$DST"
    printf 'only existing config\n' > "$DST/hyprland.conf"
    "$REAL_CP" -p -- "$DST/hyprland.conf" "$CASE_HOME/only-preimage"
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing partial-install snapshot'
    equal_files "$CASE_HOME/only-preimage" "${SNAPSHOTS[0]}/hyprland.conf"
    [[ ! -e "${SNAPSHOTS[0]}/scripts" && ! -e "${SNAPSHOTS[0]}/conf.d" ]] || fail 'snapshot invented preimages'
    check_installed
}

repeated() {
    new_case repeated
    seed_files first
    local first_preimages="$PREIMAGES" first_snapshot second_snapshot
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing first snapshot'
    first_snapshot="${SNAPSHOTS[0]}"
    seed_files second
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 2 ]] || fail 'repeat reused a snapshot'
    for second_snapshot in "${SNAPSHOTS[@]}"; do
        [[ "$second_snapshot" == "$first_snapshot" ]] || check_snapshot "$second_snapshot" "$PREIMAGES"
    done
    check_snapshot "$first_snapshot" "$first_preimages"
    check_installed
}

backup_parent_failure() {
    new_case backup_parent_failure
    seed_files first
    printf 'backup directory blocked\n' > "$DST/backups"
    run_deploy; expect_failure
    check_unchanged
    [[ "$(cat "$DST/backups")" == 'backup directory blocked' ]] || fail 'backup blocker changed'
}

backup_copy_failure() {
    new_case backup_copy_failure
    seed_files first
    # Fail the third backup copy with a real coreutils missing-parent error.
    # No filesystem permission changes are needed (this also works as root).
    cat > "$CASE_HOME/shim.sh" <<'SHIM'
cp() {
    local source="${@: -2:1}"
    if [[ "$source" == "$HOME/.config/hypr/scripts/load-split-plugin.sh" ]]; then
        "$REAL_CP" -- "$source" "$HOME/nonexistent-parent/backup"
    else
        "$REAL_CP" "$@"
    fi
}
SHIM
    run_deploy; expect_failure
    check_unchanged
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'partial backup was removed or never created'
    equal_files "$PREIMAGES/hyprland.conf" "${SNAPSHOTS[0]}/hyprland.conf"
    equal_files "$PREIMAGES/conf.d/99-split-monitor-workspaces.conf" "${SNAPSHOTS[0]}/conf.d/99-split-monitor-workspaces.conf"
    [[ ! -e "${SNAPSHOTS[0]}/scripts/split-ws-setup.sh" ]] || fail 'backup continued after failure'
}

backup_create_failure() {
    new_case backup_create_failure
    seed_files first
    cat > "$CASE_HOME/shim.sh" <<'SHIM'
mktemp() { command mktemp -d -- "$HOME/nonexistent-parent/snapshot.XXXXXXXX"; }
SHIM
    run_deploy; expect_failure
    check_unchanged
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 0 ]] || fail 'snapshot was created after mktemp failed'
}

backup_subdir_failure() {
    new_case backup_subdir_failure
    seed_files first
    cat > "$CASE_HOME/shim.sh" <<'SHIM'
mkdir() {
    local destination="${@: -1}"
    if [[ "$destination" == "$HOME/.config/hypr/backups/deploy-config."*/scripts ]]; then
        command mkdir -- "$HOME/nonexistent-parent/scripts"
    else
        command mkdir "$@"
    fi
}
SHIM
    run_deploy; expect_failure
    check_unchanged
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'partial backup was removed after mkdir failure'
    equal_files "$PREIMAGES/hyprland.conf" "${SNAPSHOTS[0]}/hyprland.conf"
    equal_files "$PREIMAGES/conf.d/99-split-monitor-workspaces.conf" "${SNAPSHOTS[0]}/conf.d/99-split-monitor-workspaces.conf"
    [[ ! -e "${SNAPSHOTS[0]}/scripts" ]] || fail 'backup continued after mkdir failure'
}

first_write_barrier() {
    new_case first_write_barrier
    seed_files first
    cat > "$CASE_HOME/shim.sh" <<'SHIM'
cp() {
    local source="${@: -2:1}" snapshot file
    if [[ "$source" == "$HOME/source with spaces/hypr/"* && ! -e "$HOME/first-write-observed" ]]; then
        printf 'observed\n' > "$HOME/first-write-observed"
        shopt -s nullglob
        for snapshot in "$HOME/.config/hypr/backups"/deploy-config.*; do
            for file in hyprland.conf conf.d/99-split-monitor-workspaces.conf scripts/load-split-plugin.sh scripts/split-dispatch-strict.sh scripts/split-limit-adjust.sh scripts/split-ws-setup.sh; do
                "$REAL_CP" -L -- "$snapshot/$file" "$HOME/observed-${file##*/}"
            done
        done
    fi
    "$REAL_CP" "$@"
}
SHIM
    run_deploy; expect_success
    local file
    [[ -f "$CASE_HOME/first-write-observed" ]] || fail 'first deployment write was not observed'
    for file in "${FILES[@]}"; do equal_files "$PREIMAGES/$file" "$CASE_HOME/observed-${file##*/}"; done
    check_installed
}

internal_file_symlink() {
    new_case internal_file_symlink
    seed_files first
    mv -- "$DST/hyprland.conf" "$CASE_HOME/original with spaces.conf"
    ln -s -- "$CASE_HOME/original with spaces.conf" "$DST/hyprland.conf"
    run_deploy; expect_success
    [[ -L "$DST/hyprland.conf" ]] || fail 'internal destination symlink was replaced'
    check_installed
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing symlink preimage snapshot'
    check_snapshot "${SNAPSHOTS[0]}" "$PREIMAGES"
}

aliased_files() {
    new_case aliased_files
    seed_files first
    rm -- "$DST/hyprland.conf"
    ln -s -- conf.d/99-split-monitor-workspaces.conf "$DST/hyprland.conf"
    save_preimages aliased
    run_deploy; expect_success
    [[ -L "$DST/hyprland.conf" ]] || fail 'alias was replaced'
    equal_files "$REPO_ROOT/hypr/conf.d/99-split-monitor-workspaces.conf" "$DST/hyprland.conf"
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing aliased preimages'
    check_snapshot "${SNAPSHOTS[0]}" "$PREIMAGES"
}

internal_parent_symlinks() {
    new_case internal_parent_symlinks
    seed_files first
    mv -- "$DST/scripts" "$CASE_HOME/config scripts with spaces"
    ln -s -- "$CASE_HOME/config scripts with spaces" "$DST/scripts"
    mv -- "$CASE_HOME/.config" "$CASE_HOME/config store"
    ln -s -- 'config store' "$CASE_HOME/.config"
    run_deploy; expect_success
    check_installed
    [[ -L "$CASE_HOME/.config" && -L "$DST/scripts" ]] || fail 'internal directory symlink changed'
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing directory-symlink snapshot'
    check_snapshot "${SNAPSHOTS[0]}" "$PREIMAGES"
}

internal_backup_symlink() {
    new_case internal_backup_symlink
    seed_files first
    mkdir -p -- "$CASE_HOME/backup store"
    ln -s -- "$CASE_HOME/backup store" "$DST/backups"
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing relocated backup'
    check_snapshot "${SNAPSHOTS[0]}" "$PREIMAGES"
    check_installed
}

external_file_symlink() {
    new_case external_file_symlink
    seed_files first
    # All outside targets are still inside the enclosing synthetic suite HOME.
    # This sibling also catches unsafe string-prefix containment checks.
    mkdir -p -- "$CASE_ROOT/home with spaces-external"
    local target="$CASE_ROOT/home with spaces-external/original.conf"
    mv -- "$DST/hyprland.conf" "$target"
    ln -s -- "$target" "$DST/hyprland.conf"
    run_deploy; expect_failure
    check_unchanged
    [[ -L "$DST/hyprland.conf" ]] || fail 'external file link changed'
    equal_files "$PREIMAGES/hyprland.conf" "$target"
}

external_parent_symlink() {
    local parent
    for parent in .config hypr conf.d scripts plugins; do
        new_case "external_parent_$parent"
        seed_files first
        local directory
        case "$parent" in
            .config) directory="$CASE_HOME/.config" ;;
            hypr) directory="$DST" ;;
            *) directory="$DST/$parent" ;;
        esac
        [[ -d "$directory" ]] || mkdir -p -- "$directory"
        local outside="$CASE_ROOT/external directory"
        mv -- "$directory" "$outside"
        ln -s -- "$outside" "$directory"
        printf 'outside guard\n' > "$outside/guard"
        run_deploy; expect_failure
        check_unchanged
        [[ "$(cat "$outside/guard")" == 'outside guard' ]] || fail "external $parent guard changed"
        [[ ! -e "$outside/backups" ]] || fail "wrote backups through external $parent"
    done
}

external_backup_symlink() {
    new_case external_backup_symlink
    seed_files first
    mkdir -p -- "$CASE_ROOT/external backup store"
    printf 'outside guard\n' > "$CASE_ROOT/external backup store/guard"
    ln -s -- "$CASE_ROOT/external backup store" "$DST/backups"
    run_deploy; expect_failure
    check_unchanged
    shopt -s dotglob nullglob
    local -a outside=("$CASE_ROOT/external backup store"/*)
    [[ "${#outside[@]}" == 1 && "$(cat "${outside[0]}")" == 'outside guard' ]] || fail 'wrote through external backup link'
}

dangling_symlinks() {
    local target
    for target in "$HOME/unused" '../outside-missing'; do
        new_case "dangling_$([[ "$target" == /* ]] && printf internal || printf external)"
        seed_files first
        rm -- "$DST/scripts/split-ws-setup.sh"
        if [[ "$target" == /* ]]; then target="$CASE_HOME/missing-script"; else target="$CASE_ROOT/outside-missing"; fi
        ln -s -- "$target" "$DST/scripts/split-ws-setup.sh"
        run_deploy; expect_failure
        local file
        for file in "${FILES[@]:0:5}"; do equal_files "$PREIMAGES/$file" "$DST/$file"; done
        [[ -L "$DST/scripts/split-ws-setup.sh" && ! -e "$target" ]] || fail 'dangling link or target changed'
        snapshots
        [[ "${#SNAPSHOTS[@]}" == 0 ]] || fail 'preflight failure created a snapshot'
    done
}

directory_destination() {
    new_case directory_destination
    seed_files first
    mv -- "$DST/scripts/split-ws-setup.sh" "$CASE_HOME/original-script"
    mkdir -- "$DST/scripts/split-ws-setup.sh"
    run_deploy; expect_failure
    local file
    for file in "${FILES[@]:0:5}"; do equal_files "$PREIMAGES/$file" "$DST/$file"; done
    [[ ! -e "$DST/scripts/split-ws-setup.sh/split-ws-setup.sh" ]] || fail 'deployed into directory destination'
}

fifo_destination() {
    new_case fifo_destination
    seed_files first
    mv -- "$DST/scripts/split-ws-setup.sh" "$CASE_HOME/original-script"
    mkfifo -- "$DST/scripts/split-ws-setup.sh"
    run_deploy; expect_failure
    local file
    for file in "${FILES[@]:0:5}"; do equal_files "$PREIMAGES/$file" "$DST/$file"; done
    [[ -p "$DST/scripts/split-ws-setup.sh" ]] || fail 'FIFO destination changed'
}

prior_backup_destination() {
    new_case prior_backup_destination
    seed_files first
    local original_preimages="$PREIMAGES"
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing original snapshot'
    local snapshot="${SNAPSHOTS[0]}"
    rm -- "$DST/hyprland.conf"
    ln -s -- "$snapshot/hyprland.conf" "$DST/hyprland.conf"
    save_preimages before_rejected_repeat
    run_deploy; expect_failure
    check_unchanged
    check_snapshot "$snapshot" "$original_preimages"
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'created a snapshot for unsafe backup destination'
}

prior_backup_parent() {
    new_case prior_backup_parent
    seed_files first
    local original_preimages="$PREIMAGES"
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing original snapshot'
    local snapshot="${SNAPSHOTS[0]}"
    mv -- "$DST/scripts" "$CASE_HOME/current scripts"
    ln -s -- "$snapshot/scripts" "$DST/scripts"
    save_preimages before_rejected_repeat
    run_deploy; expect_failure
    check_unchanged
    check_snapshot "$snapshot" "$original_preimages"
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'created snapshot for unsafe backup parent'
}

prior_backup_hardlink() {
    new_case prior_backup_hardlink
    seed_files first
    local original_preimages="$PREIMAGES"
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing original snapshot'
    local snapshot="${SNAPSHOTS[0]}"
    rm -- "$DST/hyprland.conf"
    # Use a different backup filename to catch aliases across the six paths.
    ln -- "$snapshot/scripts/split-ws-setup.sh" "$DST/hyprland.conf"
    save_preimages before_rejected_repeat
    run_deploy; expect_failure
    check_unchanged
    check_snapshot "$snapshot" "$original_preimages"
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'created snapshot for unsafe backup hardlink'
}

prior_backup_symlink_hardlink() {
    new_case prior_backup_symlink_hardlink
    seed_files first
    local original_preimages="$PREIMAGES"
    run_deploy; expect_success
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing original snapshot'
    local snapshot="${SNAPSHOTS[0]}" relocated="$CASE_HOME/relocated snapshot"
    mv -- "$snapshot" "$relocated"
    ln -s -- "$relocated" "$snapshot"
    rm -- "$DST/hyprland.conf"
    ln -- "$relocated/scripts/split-ws-setup.sh" "$DST/hyprland.conf"
    save_preimages before_rejected_repeat
    run_deploy; expect_failure
    check_unchanged
    check_snapshot "$relocated" "$original_preimages"
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 && -L "$snapshot" ]] || fail 'relocated snapshot changed'
}

internal_hardlink() {
    new_case internal_hardlink
    seed_files first
    ln -- "$DST/hyprland.conf" "$CASE_HOME/current config hardlink"
    run_deploy; expect_success
    check_installed
    equal_files "$REPO_ROOT/hypr/hyprland.conf" "$CASE_HOME/current config hardlink"
    snapshots
    [[ "${#SNAPSHOTS[@]}" == 1 ]] || fail 'missing ordinary hardlink preimage'
    check_snapshot "${SNAPSHOTS[0]}" "$PREIMAGES"
    [[ ! "$DST/hyprland.conf" -ef "${SNAPSHOTS[0]}/hyprland.conf" ]] || fail 'snapshot shares a mutable inode'
}

TESTS=(six_files clean_install partial_install repeated backup_parent_failure backup_copy_failure
    backup_create_failure backup_subdir_failure
    first_write_barrier internal_file_symlink aliased_files internal_parent_symlinks
    internal_backup_symlink external_file_symlink external_parent_symlink
    external_backup_symlink dangling_symlinks directory_destination fifo_destination
    prior_backup_destination prior_backup_parent prior_backup_hardlink
    prior_backup_symlink_hardlink internal_hardlink)
if (( $# )); then
    for requested in "$@"; do
        valid=0
        for available in "${TESTS[@]}"; do [[ "$requested" != "$available" ]] || valid=1; done
        [[ "$valid" == 1 ]] || fail "unknown test: $requested"
    done
    TESTS=("$@")
fi
failures=0
for test_name in "${TESTS[@]}"; do
    # Do not put the function in an if/|| condition: that disables errexit in Bash.
    set +e
    (set -e; "$test_name") > "$HOME/$test_name.stdout" 2> "$HOME/$test_name.stderr"
    status=$?
    set -e
    printf '%s\n' "$status" > "$HOME/$test_name.exit"
    if (( status == 0 )); then
        printf 'PASS %s\n' "$test_name"
    else
        printf 'FAIL %s (exit %s)\n' "$test_name" "$status"
        cat -- "$HOME/$test_name.stderr"
        failures=$((failures + 1))
    fi
done
printf 'Tests: %s; failures: %s\n' "${#TESTS[@]}" "$failures"
(( failures == 0 ))
