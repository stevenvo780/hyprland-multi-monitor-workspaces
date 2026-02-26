#!/usr/bin/env bash
set -euo pipefail

HYPR_CONF="${HYPR_CONF:-$HOME/.config/hypr/hyprland.conf}"
DISPATCH_SCRIPT="${DISPATCH_SCRIPT:-$HOME/.config/hypr/scripts/split-dispatch-strict.sh}"
ADJUST_SCRIPT="${ADJUST_SCRIPT:-$HOME/.config/hypr/scripts/split-limit-adjust.sh}"
LOAD_SCRIPT="${LOAD_SCRIPT:-$HOME/.config/hypr/scripts/load-split-plugin.sh}"
STATE_FILE="${STATE_FILE:-$HOME/.config/hypr/state/split-limits.json}"

RESTART_CYCLES="${RESTART_CYCLES:-20}"
SEQ_OPS="${SEQ_OPS:-2500}"
PAR_WORKERS="${PAR_WORKERS:-8}"
PAR_OPS="${PAR_OPS:-900}"

failures=0
tests=0
TEST_RDIR=""
TEST_SIG=""
HPID=""
HAD_STATE=0
STATE_BAK=""

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

inc_test() { tests=$((tests + 1)); }

fail() {
  failures=$((failures + 1))
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
  if [[ "${HAD_STATE:-0}" -eq 1 ]]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    cp -f "$STATE_BAK" "$STATE_FILE"
  else
    rm -f "$STATE_FILE"
  fi
  [[ -n "${STATE_BAK:-}" && -f "${STATE_BAK:-}" ]] && rm -f "$STATE_BAK"
}
trap cleanup EXIT

hctl() {
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" hyprctl "$@"
}

hctl_json() {
  hctl -j "$@"
}

start_hypr() {
  TEST_RDIR="$1"
  rm -rf "$TEST_RDIR"
  mkdir -p "$TEST_RDIR"
  chmod 700 "$TEST_RDIR"

  local out="$TEST_RDIR/hypr-stdout.log"
  XDG_RUNTIME_DIR="$TEST_RDIR" WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=3 Hyprland -c "$HYPR_CONF" >"$out" 2>&1 &
  HPID=$!
  TEST_SIG=""

  for _ in $(seq 1 400); do
    if [[ -d "$TEST_RDIR/hypr" ]] && ls "$TEST_RDIR/hypr" >/dev/null 2>&1; then
      TEST_SIG="$(basename "$(ls -d "$TEST_RDIR"/hypr/* | head -n1)")"
      local mon
      mon="$(XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" hyprctl -j monitors 2>/dev/null || true)"
      if [[ "$mon" == \[* ]] && echo "$mon" | jq -e 'length == 3' >/dev/null 2>&1; then
        break
      fi
    fi
    if ! kill -0 "$HPID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done

  if [[ -z "$TEST_SIG" ]]; then
    log "No levanto bien Hyprland en $TEST_RDIR"
    [[ -f "$out" ]] && sed -n '1,160p' "$out" >&2
    if [[ -n "$TEST_SIG" && -f "$TEST_RDIR/hypr/$TEST_SIG/hyprland.log" ]]; then
      sed -n '1,220p' "$TEST_RDIR/hypr/$TEST_SIG/hyprland.log" >&2
    fi
    return 1
  fi

  # Fuerza bootstrap del plugin y espera readiness.
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$LOAD_SCRIPT" >/dev/null 2>&1 || true
  for _ in $(seq 1 200); do
    if hctl plugin list 2>/dev/null | grep -q 'split-monitor-workspaces'; then
      return 0
    fi
    sleep 0.05
  done

  log "Hyprland arrancó, pero plugin no quedó listo en $TEST_RDIR"
  if [[ -f "$out" ]]; then
    sed -n '1,160p' "$out" >&2
  fi
  if [[ -f "$TEST_RDIR/hypr/$TEST_SIG/hyprland.log" ]]; then
    sed -n '1,260p' "$TEST_RDIR/hypr/$TEST_SIG/hyprland.log" >&2
  fi
  return 1
}

stop_hypr() {
  [[ -n "${HPID:-}" ]] || return 0
  kill "$HPID" >/dev/null 2>&1 || true
  wait "$HPID" >/dev/null 2>&1 || true
  HPID=""
}

workspace_count() {
  local c
  c="$(hctl getoption plugin:split-monitor-workspaces:count 2>/dev/null | awk '/int:/ {print $2; exit}')"
  if [[ -z "$c" || ! "$c" =~ ^[0-9]+$ || "$c" -lt 1 ]]; then
    c=10
  fi
  echo "$c"
}

get_monitors_sorted() {
  hctl_json monitors | jq -r 'sort_by(.x,.y) | .[].name'
}

get_monitor_local_idx() {
  local mon="$1"
  local wsid cnt
  wsid="$(hctl_json monitors | jq -r --arg m "$mon" '.[] | select(.name==$m) | .activeWorkspace.id')"
  cnt="$(workspace_count)"
  echo $(( ((wsid - 1) % cnt) + 1 ))
}

get_limit_from_state() {
  local mon="$1"
  local idx="$2"
  local d
  d="$(default_limit_for_idx "$idx")"
  if [[ -f "$STATE_FILE" ]]; then
    local v
    v="$(jq -r --arg m "$mon" '.[$m] // empty' "$STATE_FILE" 2>/dev/null || true)"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
      if (( v < 1 )); then v=1; fi
      if (( v > 10 )); then v=10; fi
      echo "$v"
      return 0
    fi
  fi
  echo "$d"
}

validate_clamp_matrix() {
  local -a mons=()
  mapfile -t mons < <(get_monitors_sorted)

  for i in "${!mons[@]}"; do
    local mon="${mons[$i]}"
    local lim req expected local_idx
    lim="$(get_limit_from_state "$mon" "$i")"
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
    for req in 1 2 3 4 5 6 7 8 9 10; do
      inc_test
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch "$req"
      local_idx="$(get_monitor_local_idx "$mon")"
      expected="$req"
      if (( expected > lim )); then expected="$lim"; fi
      if (( local_idx != expected )); then
        fail "clamp matrix mon=$mon req=$req got=$local_idx expected=$expected lim=$lim"
      fi
    done
  done
}

smoke_session() {
  inc_test
  if ! hctl plugin list | grep -q 'split-monitor-workspaces'; then
    fail "plugin no cargado"
  fi
  inc_test
  if ! hctl_json monitors | jq -e 'length == 3' >/dev/null 2>&1; then
    fail "cantidad de monitores distinta de 3"
  fi
  inc_test
  if ! hctl configerrors 2>/dev/null | awk 'NF{exit 1}'; then
    fail "hay configerrors"
  fi
}

exercise_dynamic_limits() {
  rm -f "$STATE_FILE"
  local -a mons=()
  mapfile -t mons < <(get_monitors_sorted)
  local mon0="${mons[0]}"

  hctl dispatch focusmonitor "$mon0" >/dev/null 2>&1 || true
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-monitor >/dev/null 2>&1 || true
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" inc >/dev/null 2>&1 || true
  inc_test
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 10
  local got
  got="$(get_monitor_local_idx "$mon0")"
  if (( got != 3 )); then
    fail "dynamic inc en monitor1 no aplico (got=$got expected=3)"
  fi

  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" dec >/dev/null 2>&1 || true
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 10
  got="$(get_monitor_local_idx "$mon0")"
  inc_test
  if (( got != 2 )); then
    fail "dynamic dec en monitor1 no aplico (got=$got expected=2)"
  fi

  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-all >/dev/null 2>&1 || true
  validate_clamp_matrix
}

run_sequential_stress() {
  local -a mons=()
  mapfile -t mons < <(get_monitors_sorted)
  local mon_count="${#mons[@]}"
  local n mon_idx mon req action

  for n in $(seq 1 "$SEQ_OPS"); do
    mon_idx=$((RANDOM % mon_count))
    mon="${mons[$mon_idx]}"
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true

    action=$((RANDOM % 100))
    req=$((1 + RANDOM % 10))
    if (( action < 70 )); then
      inc_test
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch "$req"
      local lim got expected
      lim="$(get_limit_from_state "$mon" "$mon_idx")"
      got="$(get_monitor_local_idx "$mon")"
      expected="$req"
      if (( expected > lim )); then expected="$lim"; fi
      if (( got != expected )); then
        fail "seq stress mon=$mon req=$req got=$got expected=$expected lim=$lim iter=$n"
      fi
    elif (( action < 85 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" move "$req" >/dev/null 2>&1 || true
    elif (( action < 90 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" inc >/dev/null 2>&1 || true
    elif (( action < 95 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" dec >/dev/null 2>&1 || true
    elif (( action < 98 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-monitor >/dev/null 2>&1 || true
    else
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" show >/dev/null 2>&1 || true
    fi

    if ! kill -0 "$HPID" >/dev/null 2>&1; then
      fail "Hyprland murio en seq stress iter=$n"
      return 1
    fi
  done
}

stress_worker() {
  local worker_id="$1"
  local -a mons=()
  mapfile -t mons < <(get_monitors_sorted)
  local mon_count="${#mons[@]}"
  local n mon req action
  for n in $(seq 1 "$PAR_OPS"); do
    mon="${mons[$((RANDOM % mon_count))]}"
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
    req=$((1 + RANDOM % 10))
    action=$((RANDOM % 100))
    if (( action < 65 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch "$req" >/dev/null 2>&1 || true
    elif (( action < 80 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" move "$req" >/dev/null 2>&1 || true
    elif (( action < 88 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" inc >/dev/null 2>&1 || true
    elif (( action < 96 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" dec >/dev/null 2>&1 || true
    elif (( action < 99 )); then
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-monitor >/dev/null 2>&1 || true
    else
      XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-all >/dev/null 2>&1 || true
    fi
  done
  echo "worker-$worker_id done"
}

run_parallel_stress() {
  local -a pids=()
  local w
  for w in $(seq 1 "$PAR_WORKERS"); do
    stress_worker "$w" >/dev/null 2>&1 &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do
    wait "$p"
  done

  inc_test
  if [[ -f "$STATE_FILE" ]] && ! jq -e 'type=="object"' "$STATE_FILE" >/dev/null 2>&1; then
    fail "state file corrupto tras parallel stress"
  fi

  inc_test
  if ! kill -0 "$HPID" >/dev/null 2>&1; then
    fail "Hyprland murio en parallel stress"
  fi
}

quick_restart_smoke() {
  local cycle="$1"
  local rdir="/tmp/hs${cycle}"
  if ! start_hypr "$rdir"; then
    fail "restart cycle=$cycle no inicia"
    return 1
  fi
  smoke_session
  # Asegura baseline por defecto 2/3/4 antes de validar post-restart.
  rm -f "$STATE_FILE"
  XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$ADJUST_SCRIPT" reset-all >/dev/null 2>&1 || true
  local -a mons=()
  mapfile -t mons < <(get_monitors_sorted)
  local i mon got expected
  for i in "${!mons[@]}"; do
    mon="${mons[$i]}"
    hctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
    XDG_RUNTIME_DIR="$TEST_RDIR" HYPRLAND_INSTANCE_SIGNATURE="$TEST_SIG" "$DISPATCH_SCRIPT" switch 10
    got="$(get_monitor_local_idx "$mon")"
    expected="$(default_limit_for_idx "$i")"
    inc_test
    if (( got != expected )); then
      fail "restart cycle=$cycle mon=$mon got=$got expected=$expected"
    fi
  done
  stop_hypr
}

main() {
  for p in "$HYPR_CONF" "$DISPATCH_SCRIPT" "$ADJUST_SCRIPT"; do
    if [[ ! -f "$p" ]]; then
      echo "Falta archivo requerido: $p" >&2
      exit 2
    fi
  done
  if [[ ! -f "$LOAD_SCRIPT" ]]; then
    echo "Falta archivo requerido: $LOAD_SCRIPT" >&2
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq es requerido" >&2
    exit 2
  fi
  if ! command -v Hyprland >/dev/null 2>&1 || ! command -v hyprctl >/dev/null 2>&1; then
    echo "Hyprland/hyprctl no disponibles" >&2
    exit 2
  fi

  mkdir -p "$(dirname "$STATE_FILE")"
  STATE_BAK="$(mktemp)"
  if [[ -f "$STATE_FILE" ]]; then
    HAD_STATE=1
    cp -f "$STATE_FILE" "$STATE_BAK"
  else
    HAD_STATE=0
  fi

  log "Iniciando sesion principal de pruebas..."
  start_hypr /tmp/hs0
  smoke_session
  validate_clamp_matrix
  exercise_dynamic_limits
  log "Stress secuencial (${SEQ_OPS} ops)..."
  run_sequential_stress
  log "Stress paralelo (${PAR_WORKERS} workers x ${PAR_OPS} ops)..."
  run_parallel_stress
  log "Validacion final post-stress..."
  validate_clamp_matrix
  stop_hypr

  log "Soak de reinicios (${RESTART_CYCLES} ciclos)..."
  local c
  for c in $(seq 1 "$RESTART_CYCLES"); do
    quick_restart_smoke "$c"
  done

  echo "==========================================="
  echo "Tests ejecutados: $tests"
  echo "Fallos: $failures"
  if (( failures > 0 )); then
    exit 1
  fi
  echo "Estado: OK"
}

main "$@"
