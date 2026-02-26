# Hyprland Multi-Monitor Workspaces (Snapshot)

Configuracion lista para Hyprland con enfoque en multitarea multi-monitor y plugin `split-monitor-workspaces`.

## Incluye

- `hypr/hyprland.conf`
- `hypr/conf.d/99-split-monitor-workspaces.conf`
- `hypr/scripts/load-split-plugin.sh`
- `hypr/scripts/split-ws-setup.sh`
- `scripts/build-plugin.sh` (compila plugin pinneado)
- `scripts/deploy-config.sh` (instala esta config en `~/.config/hypr`)

## Versiones objetivo

- Hyprland: `v0.41.2`
- Plugin split-monitor-workspaces: commit `a03a32c6e0f64c05c093ced864a326b4ab58eabf`

## Uso rapido

1. Compilar plugin:

   ```bash
   ./scripts/build-plugin.sh
   ```

2. Copiar configuracion a tu perfil:

   ```bash
   ./scripts/deploy-config.sh
   ```

3. Iniciar sesion Hyprland y verificar:

   ```bash
   hyprctl plugin list
   hyprctl binds | rg split-
   ```

## Nota

En esta version del plugin (v1.1.0), los dispatchers disponibles usados por esta config son:

- `split-workspace`
- `split-movetoworkspace`
- `split-movetoworkspacesilent`
- `split-changemonitor`
- `split-changemonitorsilent`
