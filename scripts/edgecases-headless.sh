#!/usr/bin/env bash
set -euo pipefail

HYPR_CONF="${HYPR_CONF:-$HOME/.config/hypr/hyprland.conf}"
LOAD_SCRIPT="${LOAD_SCRIPT:-$HOME/.config/hypr/scripts/load-split-plugin.sh}"
DISPATCH_SCRIPT="${DISPATCH_SCRIPT:-$HOME/.config/hypr/scripts/split-dispatch-strict.sh}"
ADJUST_SCRIPT="${ADJUST_SCRIPT:-$HOME/.config/hypr/scripts/split-limit-adjust.sh}"
STATE_FILE="${STATE_FILE:-$HOME/.config/hypr/state/split-limits.json}"
PLUGIN_SO="${PLUGIN_SO:-$HOME/.config/hypr/plugins/split-monitor-workspaces.so}"

OUTPUT_MATRIX="${OUTPUT_MATRIX:-1 2 3 5}"
RAPID_ITERS="${RAPID_ITERS:-700}"

fails=0
tests=0
session_seq=0
TEST_RDIR=""
TEST_SIG=""
HPID=""

STATE_BAK="$(mktemp)"
STATE_WAS_PRESENT=0
PLUGIN_WAS_PRESENT=0
PLUGIN_BAK=""

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
inc_test() { tests=$((tests + 1)); }
fail() {
  fails=$((fails + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

default_limit_for_idx() {
  local idx="$1"
  case "$idx" in
    0) echo 2 ;;
    1) echo 3 ;;
    *) echo 4 ;;
  esac
}

cleanup() {
  if [[ -n "${HPID:-}" ]]; then
    kill "$HPID" >/dev/null 2>&1 || true
    wait "$HPID" >/dev/null 2>&1 || true
  fi

  if [[ "$STATE_WAS_PRESENT" -eq 1 ]]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    cp -f "$STATE_BAK" "$STATE_FILE"
  else
    rm -f "$STATE_FILE"
  fi
  rm -f "$STATE_BAK"

  if [[ "$PLUGIN_WAS_PRESENT" -eq 1 && -n "${PLUGIN_BAK:-}" && -f "${PLUGIN_BAK:-}" ]]; then
    mv -f "$PLUGIN_BAK" "$PLUGIN_SO"
  fi
}
trap cleanup EXIT

hctl() {
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" hyprctl "$@"
}

hctl_json() {
  hctl -j "$@"
}

workspace_count() {
  local c
  c="$(hctl getoption plugin:split-monitor-workspaces:count 2>/dev/null | awk '/int:/ {print $2; exit}')"
  if [[ -z "$c" || ! "$c" =~ ^[0-9]+$ || "$c" -lt 1 ]]; then
    c=10
  fi
  echo "$c"
}

sorted_monitors() {
  hctl_json monitors | jq -r 'sort_by(.x,.y) | .[].name'
}

monitor_idx() {
  local mon="$1"
  hctl_json monitors | jq -r --arg m "$mon" 'sort_by(.x,.y) | to_entries | map(select(.value.name==$m)) | if length > 0 then .[0].key else 0 end'
}

local_ws_idx() {
  local mon="$1"
  local wsid cnt
  wsid="$(hctl_json monitors | jq -r --arg m "$mon" '.[] | select(.name==$m) | .activeWorkspace.id')"
  cnt="$(workspace_count)"
  echo $(( ((wsid - 1) % cnt) + 1 ))
}

state_limit_for_mon() {
  local mon="$1"
  local idx="$2"
  local v
  v="$(jq -r --arg m "$mon" '.[$m] // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]]; then
    v="$(default_limit_for_idx "$idx")"
  fi
  if (( v < 1 )); then v=1; fi
  if (( v > 10 )); then v=10; fi
  echo "$v"
}

assert_eq() {
  local got="$1"
  local expected="$2"
  local msg="$3"
  inc_test
  if [[ "$got" != "$expected" ]]; then
    fail "$msg (got=$got expected=$expected)"
  fi
}

assert_le() {
  local got="$1"
  local max="$2"
  local msg="$3"
  inc_test
  if (( got > max )); then
    fail "$msg (got=$got max=$max)"
  fi
}

assert_rc0() {
  local rc="$1"
  local msg="$2"
  inc_test
  if (( rc != 0 )); then
    fail "$msg (rc=$rc)"
  fi
}

ensure_alive() {
  inc_test
  if ! kill -0 "$HPID" >/dev/null 2>&1; then
    fail "Hyprland no sigue vivo"
  fi
}

start_session() {
  local outputs="$1"
  local expect_plugin="${2:-yes}"
  session_seq=$((session_seq + 1))
  TEST_RDIR="/tmp/he${session_seq}"
  rm -rf "$TEST_RDIR"
  mkdir -p "$TEST_RDIR"
  chmod 700 "$TEST_RDIR"

  local out="$TEST_RDIR/stdout.log"
  XDG_RUNTIME_DIR="$TEST_RDIR" WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS="$outputs" Hyprland -c "$HYPR_CONF" >"$out" 2>&1 &
  HPID=$!
  TEST_SIG=""

  for _ in $(seq 1 400); do
    if [[ -d "$TEST_RDIR/hypr" ]] && ls "$TEST_RDIR/hypr" >/dev/null 2>&1; then
      TEST_SIG="$(basename "$(ls -d "$TEST_RDIR"/hypr/* | head -n1)")"
      local mon
      mon="$(XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" hyprctl -j monitors 2>/dev/null || true)"
      if [[ "$mon" == \[* ]] && echo "$mon" | jq -e --argjson n "$outputs" 'length == $n' >/dev/null 2>&1; then
        break
      fi
    fi
    if ! kill -0 "$HPID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done

  if [[ -z "$TEST_SIG" ]]; then
    fail "session outputs=$outputs no levantó firma"
    [[ -f "$out" ]] && sed -n '1,200p' "$out" >&2
    return 1
  fi

  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$LOAD_SCRIPT" >/dev/null 2>&1 || true
  if [[ "$expect_plugin" == "yes" ]]; then
    for _ in $(seq 1 200); do
      if hctl plugin list 2>/dev/null | grep -q 'split-monitor-workspaces'; then
        break
      fi
      sleep 0.05
    done
  fi

  local n
  n="$(hctl_json monitors | jq -r 'length')"
  assert_eq "$n" "$outputs" "cantidad de monitores inesperada en arranque"
}

stop_session() {
  if [[ -n "${HPID:-}" ]]; then
    kill "$HPID" >/dev/null 2>&1 || true
    wait "$HPID" >/dev/null 2>&1 || true
  fi
  HPID=""
  TEST_RDIR=""
  TEST_SIG=""
}

test_defaults_clamp() {
  rm -f "$STATE_FILE"
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-all >/dev/null 2>&1 || true

  local -a mons=()
  mapfile -t mons < <(sorted_monitors)

  local i mon req lim exp got
  for i in "${!mons[@]}"; do
    mon="${mons[$i]}"
    lim="$(default_limit_for_idx "$i")"
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
    for req in 1 2 3 4 5 10 999999; do
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch "$req"
      got="$(local_ws_idx "$mon")"
      exp="$req"
      if (( exp > lim )); then exp="$lim"; fi
      assert_eq "$got" "$exp" "default clamp mon=$mon req=$req"
    done
  done
}

test_invalid_inputs() {
  local mon before after rc
  mon="$(sorted_monitors | head -n1)"
  hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 2
  before="$(local_ws_idx "$mon")"

  set +e
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 0 >/dev/null 2>&1
  rc=$?
  set -e
  assert_rc0 "$rc" "invalid input 0 no debe romper"
  after="$(local_ws_idx "$mon")"
  assert_eq "$after" "$before" "invalid input 0 debe conservar workspace"

  set +e
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch -1 >/dev/null 2>&1
  rc=$?
  set -e
  assert_rc0 "$rc" "invalid input -1 no debe romper"
  after="$(local_ws_idx "$mon")"
  assert_eq "$after" "$before" "invalid input -1 debe conservar workspace"

  set +e
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch abc >/dev/null 2>&1
  rc=$?
  set -e
  assert_rc0 "$rc" "invalid input texto no debe romper"
  after="$(local_ws_idx "$mon")"
  assert_eq "$after" "$before" "invalid input texto debe conservar workspace"

  set +e
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch "" >/dev/null 2>&1
  rc=$?
  set -e
  assert_rc0 "$rc" "invalid input vacio no debe romper"
  after="$(local_ws_idx "$mon")"
  assert_eq "$after" "$before" "invalid input vacio debe conservar workspace"
}

test_dynamic_floor_ceiling() {
  local mon got
  mon="$(sorted_monitors | head -n1)"
  hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
  rm -f "$STATE_FILE"
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-monitor >/dev/null 2>&1 || true

  for _ in $(seq 1 20); do
    XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" dec >/dev/null 2>&1 || true
  done
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 10
  got="$(local_ws_idx "$mon")"
  assert_eq "$got" "1" "dynamic floor debe clamplear a 1"

  for _ in $(seq 1 20); do
    XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" inc >/dev/null 2>&1 || true
  done
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 10
  got="$(local_ws_idx "$mon")"
  assert_eq "$got" "10" "dynamic ceiling debe clamplear a 10"
}

test_corrupted_state_recovery() {
  local mon got rc
  mon="$(sorted_monitors | head -n1)"
  printf '}{\n' > "$STATE_FILE"

  set +e
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" inc >/dev/null 2>&1
  rc=$?
  set -e
  assert_rc0 "$rc" "state corrupto debe auto-recuperarse"

  inc_test
  if ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    fail "state no quedó como objeto JSON tras recuperación"
  fi

  hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 10
  got="$(local_ws_idx "$mon")"
  assert_le "$got" "10" "workspace local tras recovery debe quedar en rango"
}

test_out_of_range_state_values() {
  local -a mons=()
  mapfile -t mons < <(sorted_monitors)

  local tmp
  tmp="$(mktemp)"
  printf '{}\n' > "$tmp"
  if [[ "${#mons[@]}" -ge 1 ]]; then
    jq --arg m "${mons[0]}" --argjson v 0 '.[$m]=$v' "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
  fi
  if [[ "${#mons[@]}" -ge 2 ]]; then
    jq --arg m "${mons[1]}" --argjson v 999 '.[$m]=$v' "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
  fi
  if [[ "${#mons[@]}" -ge 3 ]]; then
    jq --arg m "${mons[2]}" --arg v "abc" '.[$m]=$v' "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
  fi
  jq --arg m "STALE-MONITOR" --argjson v 7 '.[$m]=$v' "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
  cp -f "$tmp" "$STATE_FILE"
  rm -f "$tmp"

  local i mon got lim
  for i in "${!mons[@]}"; do
    mon="${mons[$i]}"
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
    XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 10
    got="$(local_ws_idx "$mon")"
    lim="$(state_limit_for_mon "$mon" "$i")"
    assert_eq "$got" "$lim" "clamp con estado fuera de rango mon=$mon"
  done
}

test_reset_all_restores_defaults() {
  local -a mons=()
  mapfile -t mons < <(sorted_monitors)
  local i mon got exp

  for mon in "${mons[@]}"; do
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
    for _ in $(seq 1 4); do
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" inc >/dev/null 2>&1 || true
    done
  done

  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-all >/dev/null 2>&1 || true
  for i in "${!mons[@]}"; do
    mon="${mons[$i]}"
    exp="$(default_limit_for_idx "$i")"
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
    XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 10
    got="$(local_ws_idx "$mon")"
    assert_eq "$got" "$exp" "reset-all debe restaurar defaults mon=$mon"
  done
}

test_rapid_mixed_ops() {
  local n mon req action focused fidx lim got
  local -a mons=()
  mapfile -t mons < <(sorted_monitors)
  local mcount="${#mons[@]}"

  rm -f "$STATE_FILE"
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-all >/dev/null 2>&1 || true

  for n in $(seq 1 "$RAPID_ITERS"); do
    mon="${mons[$((RANDOM % mcount))]}"
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
    req=$((1 + RANDOM % 10))
    action=$((RANDOM % 100))

    if (( action < 60 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch "$req" >/dev/null 2>&1 || true
    elif (( action < 80 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" move "$req" >/dev/null 2>&1 || true
    elif (( action < 87 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" inc >/dev/null 2>&1 || true
    elif (( action < 94 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" dec >/dev/null 2>&1 || true
    elif (( action < 98 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-monitor >/dev/null 2>&1 || true
    else
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" show >/dev/null 2>&1 || true
    fi

    if (( n % 35 == 0 )); then
      ensure_alive
      focused="$(hctl_json monitors | jq -r 'sort_by(.x,.y) | map(select(.focused==true)) | if length>0 then .[0].name else .[0].name end')"
      fidx="$(monitor_idx "$focused")"
      lim="$(state_limit_for_mon "$focused" "$fidx")"
      got="$(local_ws_idx "$focused")"
      assert_le "$got" "$lim" "rapid mixed debe respetar limite (mon=$focused)"
    fi
  done
}

test_plugin_missing_degradation() {
  local rc
  if [[ -f "$PLUGIN_SO" ]]; then
    PLUGIN_WAS_PRESENT=1
    PLUGIN_BAK="$(mktemp)"
    mv -f "$PLUGIN_SO" "$PLUGIN_BAK"
  else
    PLUGIN_WAS_PRESENT=0
  fi

  start_session 3 no
  inc_test
  if hctl plugin list 2>/dev/null | grep -q 'split-monitor-workspaces'; then
    fail "sin .so, el plugin no debería quedar cargado"
  fi

  set +e
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 5 >/dev/null 2>&1
  rc=$?
  set -e
  assert_rc0 "$rc" "dispatch sin plugin no debe romper"

  set +e
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" inc >/dev/null 2>&1
  rc=$?
  set -e
  assert_rc0 "$rc" "adjust sin plugin no debe romper"
  stop_session

  if [[ "$PLUGIN_WAS_PRESENT" -eq 1 && -n "${PLUGIN_BAK:-}" && -f "${PLUGIN_BAK:-}" ]]; then
    mv -f "$PLUGIN_BAK" "$PLUGIN_SO"
    PLUGIN_BAK=""
    PLUGIN_WAS_PRESENT=0
  fi
}

main() {
  for p in "$HYPR_CONF" "$LOAD_SCRIPT" "$DISPATCH_SCRIPT" "$ADJUST_SCRIPT"; do
    if [[ ! -f "$p" ]]; then
      echo "Falta archivo requerido: $p" >&2
      exit 2
    fi
  done
  if ! command -v Hyprland >/dev/null 2>&1 || ! command -v hyprctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "Faltan dependencias: Hyprland/hyprctl/jq" >&2
    exit 2
  fi

  if [[ -f "$STATE_FILE" ]]; then
    STATE_WAS_PRESENT=1
    cp -f "$STATE_FILE" "$STATE_BAK"
  fi

  local outs
  for outs in $OUTPUT_MATRIX; do
    log "Edge session: outputs=$outs"
    start_session "$outs" yes
    test_defaults_clamp
    test_invalid_inputs
    test_dynamic_floor_ceiling
    test_corrupted_state_recovery
    test_out_of_range_state_values
    test_reset_all_restores_defaults
    test_rapid_mixed_ops
    stop_session
  done

  log "Edge session: plugin ausente"
  test_plugin_missing_degradation

  echo "==========================================="
  echo "Edge tests ejecutados: $tests"
  echo "Fallos: $fails"
  if (( fails > 0 )); then
    exit 1
  fi
  echo "Estado: OK"
}

main "$@"
