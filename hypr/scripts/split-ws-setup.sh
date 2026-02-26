#!/usr/bin/env bash
set -euo pipefail

# Espera breve hasta que Hyprland exponga la lista de monitores.
for _ in $(seq 1 60); do
    if hyprctl monitors -j >/tmp/hypr-monitors.json 2>/dev/null && jq -e 'length > 0' /tmp/hypr-monitors.json >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

if ! jq -e 'length > 0' /tmp/hypr-monitors.json >/dev/null 2>&1; then
    exit 0
fi

mapfile -t monitors < <(jq -r 'sort_by(.x, .y) | .[].name' /tmp/hypr-monitors.json)

if [ "${#monitors[@]}" -eq 0 ]; then
    exit 0
fi

# Config base del plugin.
# En v1.1.0 (Hyprland 0.41.x) solo count/keep_focused/enable_notifications son efectivos.
hyprctl keyword plugin:split-monitor-workspaces:count 4 >/dev/null 2>&1 || true
hyprctl keyword plugin:split-monitor-workspaces:keep_focused 1 >/dev/null 2>&1 || true
hyprctl keyword plugin:split-monitor-workspaces:enable_notifications 0 >/dev/null 2>&1 || true

# Prioridad de monitor en orden físico (izq->der, arriba->abajo)
priority=""
for m in "${monitors[@]}"; do
    if [ -z "$priority" ]; then
        priority="$m"
    else
        priority="$priority, $m"
    fi
done

hyprctl keyword plugin:split-monitor-workspaces:monitor_priority "$priority" >/dev/null 2>&1 || true

# Objetivo pedido: monitor1=2, monitor2=3, monitor3=4.
# Si el plugin soporta max_workspaces (versiones más nuevas), se aplicará.
limits=(2 3 4)
for i in "${!monitors[@]}"; do
    if [ "$i" -lt "${#limits[@]}" ]; then
        limit="${limits[$i]}"
    else
        limit=4
    fi
    hyprctl keyword plugin:split-monitor-workspaces:max_workspaces "${monitors[$i]}, ${limit}" >/dev/null 2>&1 || true
done

# Notificación visible al iniciar sesión.
summary="split-monitor-workspaces activo"
detail=""
for i in "${!monitors[@]}"; do
    idx=$((i + 1))
    if [ "$i" -lt "${#limits[@]}" ]; then
        limit="${limits[$i]}"
    else
        limit=4
    fi
    detail+="M${idx}:${monitors[$i]}=${limit} "
done
hyprctl notify -1 3000 "rgb(88ccff)" "$summary - $detail" >/dev/null 2>&1 || true
