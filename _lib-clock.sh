#!/usr/bin/env bash
# =============================================================================
# FuelManager Kiosk — shared clock & NTP helpers
# -----------------------------------------------------------------------------
# Source'eable desde otros scripts (install-raspberry.sh, setup-system.sh) que
# necesiten garantizar un reloj sano antes de tocar apt o config del sistema.
#
# Requisitos del script que lo sourcee:
#   - Funciones log(), warn(), fail() ya definidas.
#
# API expuesta:
#   check_clock_or_fail   — fatal si el reloj está atrasado respecto al baseline.
#   ensure_ntp_synced     — activa NTP y espera primer sync hasta 30s; warn si no.
#
# Mantenimiento: actualizar SYSTEM_CLOCK_BASELINE_TS y _HUMAN una vez al año.
# =============================================================================

# Baseline: 2026-01-01 00:00:00 UTC. Actualizar al inicio de cada año natural.
SYSTEM_CLOCK_BASELINE_TS=1767225600
SYSTEM_CLOCK_BASELINE_HUMAN="2026-01-01"

check_clock_or_fail() {
  local now_ts
  now_ts=$(date +%s)
  if [[ $now_ts -lt $SYSTEM_CLOCK_BASELINE_TS ]]; then
    fail "Reloj del sistema ATRASADO: $(date)

El reloj parece anterior a $SYSTEM_CLOCK_BASELINE_HUMAN. Eso hará que apt
rechace los repos Debian con 'Release file is not valid yet' y este script
fallará más adelante.

Causa típica: Pi 5 sin batería de respaldo del RTC (CR2032) tras un apagón,
o NTP bloqueado/no sincronizado.

Arregla el reloj y vuelve a ejecutar:

  sudo timedatectl set-ntp true
  sudo systemctl restart systemd-timesyncd
  sleep 5
  date    # debería mostrar la fecha correcta

Si la red del cliente bloquea NTP:

  sudo timedatectl set-ntp false
  sudo timedatectl set-time 'YYYY-MM-DD HH:MM:SS'

Solución de raíz (para evitar reincidir): instalar una batería CR2032 en el
slot RTC de la Pi 5."
  fi
}

ensure_ntp_synced() {
  if ! command -v timedatectl >/dev/null 2>&1; then
    return 0
  fi

  log "Verificando sincronización NTP..."
  if ! timedatectl set-ntp true 2>/dev/null; then
    warn "No se pudo activar NTP con timedatectl. Continuando con el reloj actual."
  fi

  local ntp_sync
  ntp_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  if [[ "$ntp_sync" != "yes" ]]; then
    log "  NTP activado, esperando primer sync (hasta 30s)..."
    local _i
    for _i in $(seq 1 15); do
      sleep 2
      ntp_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
      if [[ "$ntp_sync" == "yes" ]]; then break; fi
    done
  fi

  if [[ "$ntp_sync" == "yes" ]]; then
    log "  NTP sincronizado. Hora actual: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  else
    warn "Reloj actual ($(date '+%Y-%m-%d %H:%M:%S')) aceptado, pero NTP NO sincroniza."
    warn "  Probable: la red bloquea UDP/123 a pool.ntp.org o no hay internet."
    warn "  El script continúa. El reloj se irá desfasando hasta que NTP funcione."
  fi
}
