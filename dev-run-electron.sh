#!/usr/bin/env bash
#
# dev-run-electron.sh — arranca Electron en modo dev (electronmon).
#
# En Linux (Raspberry Pi) añade lo que hace el launcher de producción para que
# el BLE (bleno / iBeacon) funcione también en desarrollo:
#
#   1) setcap cap_net_raw,cap_net_admin+eip al binario de Electron.
#      bleno abre el socket HCI (cap_net_raw) y necesita cap_net_admin para el
#      canal HCI de usuario; sin AMBAS, bleno cae en 'unauthorized' y el kiosko
#      reporta "BLE not advertising — check setcap on Electron".
#      OJO: el user suele tener cap_net_raw por ambient (pam_cap), pero NO
#      cap_net_admin → hay que aplicarlo por file-caps al binario.
#
#   2) --no-sandbox. Al poner file-caps, el kernel marca AT_SECURE=1 y el
#      sandbox SUID de Chromium se niega a arrancar en dev (crash-loop: Electron
#      sale y electronmon queda esperando). Producción ya lo lanza con
#      --no-sandbox (install-raspberry.sh, exec "$INNER_BIN" --no-sandbox).
#
# En macOS/Windows es un passthrough directo a electronmon (sin cambios de dev).
#
# Idempotente: sólo aplica setcap si falta cap_net_admin.
set -eu

ELECTRONMON="./node_modules/.bin/electronmon"

if [ "$(uname)" = "Linux" ]; then
  # Ruta real del binario de Electron que usa este proyecto.
  BIN="$(node -e 'process.stdout.write(require("electron"))' 2>/dev/null || true)"

  if [ -n "$BIN" ] && [ -x "$BIN" ]; then
    if ! /usr/sbin/getcap "$BIN" 2>/dev/null | grep -q cap_net_admin; then
      echo "[dev-ble] aplicando setcap cap_net_raw,cap_net_admin a Electron…"
      if sudo -n /usr/sbin/setcap cap_net_raw,cap_net_admin+eip "$BIN" 2>&1; then
        echo "[dev-ble] setcap OK — bleno podrá anunciar el iBeacon."
      else
        echo "[dev-ble] AVISO: setcap falló (¿sudo sin NOPASSWD?). El BLE no anunciará en dev."
      fi
    fi
  else
    echo "[dev-ble] AVISO: no se resolvió el binario de Electron; se omite setcap."
  fi

  # --no-sandbox obligatorio cuando el binario tiene file-caps (AT_SECURE).
  exec "$ELECTRONMON" . --no-sandbox
fi

# macOS / Windows: arranque dev normal.
exec "$ELECTRONMON" .
