# Hyprland Multi-Monitor Workspaces (Snapshot)

Configuracion lista para Hyprland con enfoque en multitarea multi-monitor y plugin `split-monitor-workspaces`.

## Incluye

- `hypr/hyprland.conf`
- `hypr/conf.d/99-split-monitor-workspaces.conf`
- `hypr/scripts/load-split-plugin.sh`
- `hypr/scripts/split-dispatch-strict.sh`
- `hypr/scripts/split-limit-adjust.sh`
- `hypr/scripts/split-ws-setup.sh`
- `scripts/build-plugin.sh` (compila plugin pinneado)
- `scripts/deploy-config.sh` (instala esta config en `~/.config/hypr`)
- `scripts/stress-headless.sh` (pruebas intensivas automatizadas)
- `scripts/edgecases-headless.sh` (bateria de edge cases)

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

4. Ejecutar bateria intensiva de estabilidad:

   ```bash
   ./scripts/stress-headless.sh
   ```

5. Ejecutar edge cases:

   ```bash
   ./scripts/edgecases-headless.sh
   ```

## Nota

En esta version del plugin (v1.1.0), los dispatchers disponibles usados por esta config son:

- `split-workspace`
- `split-movetoworkspace`
- `split-movetoworkspacesilent`
- `split-changemonitor`
- `split-changemonitorsilent`

Adicionalmente, esta configuracion aplica una capa de control estricto por monitor via `split-dispatch-strict.sh`:

- Monitor 1: max `2` workspaces locales
- Monitor 2: max `3` workspaces locales
- Monitor 3+: max `4` workspaces locales

Esto fuerza el comportamiento `2/3/4` en los atajos configurados aunque el plugin 1.1.0 no exponga limites por monitor nativos.

## Resultados de stress (2026-02-26)

- Corrida intensa A: `RESTART_CYCLES=30 SEQ_OPS=6000 PAR_WORKERS=12 PAR_OPS=1800` -> `Fallos: 0`.
- Corrida intensa B: `RESTART_CYCLES=50 SEQ_OPS=10000 PAR_WORKERS=16 PAR_OPS=2600` -> `Fallos: 0`.

Nota tecnica:
- En pruebas headless de Hyprland 0.41.2, usar `XDG_RUNTIME_DIR` largo puede provocar crash por overflow en socket path.
- El harness usa rutas cortas (`/tmp/hs*`) para evitar falsos negativos de laboratorio.

## Resultados de edge cases (2026-02-26)

- Corrida edge A: `OUTPUT_MATRIX='1 2 3 5' RAPID_ITERS=500` -> `Fallos: 0`.
- Corrida edge B: `OUTPUT_MATRIX='3 5' RAPID_ITERS=1400` -> `Fallos: 0`.

Cobertura clave:
- clamp por defecto `2/3/4` con `1,2,3,5` monitores.
- requests invalidos (`0`, negativos, texto, vacio) y request gigante (`999999`).
- limites dinamicos en extremos (`1` y `10`).
- estado corrupto de `split-limits.json` con autorecuperacion.
- valores fuera de rango y claves de monitores obsoletas.
- degradacion controlada cuando falta el `.so` del plugin.
