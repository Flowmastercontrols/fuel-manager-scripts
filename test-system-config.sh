#!/bin/bash
# Prueba _lib-system-config.sh sin Raspberry: con un cmdline.txt, un
# journald.conf y un /var/log/journal falsos en un directorio temporal.
#
# Lo que importa: que los parámetros entren UNA vez, en la MISMA línea (un salto
# de línea de más en cmdline.txt y el kernel ignora lo que va detrás), sin
# romper lo que ya hubiera; y que repetir la instalación no cambie nada.
#
#   npm run test:system-config

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fallos=0
bien() { echo "  ✓ $1"; }
mal() { echo "  ✗ $1"; fallos=$((fallos + 1)); }

export SYSCFG_CMDLINE_FILE="$TMP/boot/cmdline.txt"
export SYSCFG_JOURNALD_CONF="$TMP/etc/journald.conf"
export SYSCFG_JOURNALD_DROPIN="$TMP/etc/journald.conf.d/90-fuelmanager-persistent.conf"
export SYSCFG_JOURNAL_DIR="$TMP/var/log/journal"
export SYSCFG_MACHINE_ID_FILE="$TMP/etc/machine-id"
export SYSCFG_NO_RESTART=1

log() { :; }
ok() { :; }
warn() { :; }
# shellcheck source=/dev/null
source "$REPO/scripts/_lib-system-config.sh"

mkdir -p "$TMP/boot" "$TMP/etc"
ORIGINAL='console=tty1 root=PARTUUID=2bd488d7-02 rootfstype=ext4 rootwait quiet splash'

echo "cmdline.txt"

# El de kiosk-cccccccc: una línea SIN salto final.
printf '%s' "$ORIGINAL" > "$SYSCFG_CMDLINE_FILE"
[[ "$(missing_kernel_params "$SYSCFG_CMDLINE_FILE" | wc -l | tr -d ' ')" == 3 ]] \
  && bien "detecta los tres que faltan" || mal "no detecta los tres que faltan"

ensure_required_kernel_params; rc=$?
[[ $rc -eq 10 ]] && bien "avisa de que hace falta reiniciar (10)" || mal "devolvió $rc, no 10"
[[ "$(wc -l < "$SYSCFG_CMDLINE_FILE" | tr -d ' ')" -le 1 && "$(grep -c . "$SYSCFG_CMDLINE_FILE")" == 1 ]] \
  && bien "sigue siendo una sola línea" || mal "cmdline.txt tiene más de una línea"
[[ "$(cat "$SYSCFG_CMDLINE_FILE")" == "$ORIGINAL nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off" ]] \
  && bien "conserva lo que había y añade al final" || mal "contenido inesperado: $(cat "$SYSCFG_CMDLINE_FILE")"
[[ -z "$(missing_kernel_params "$SYSCFG_CMDLINE_FILE")" ]] \
  && bien "ya no falta ninguno" || mal "siguen faltando: $(missing_kernel_params "$SYSCFG_CMDLINE_FILE")"
ls "$SYSCFG_CMDLINE_FILE".bak-* >/dev/null 2>&1 \
  && bien "deja copia de seguridad" || mal "no deja copia de seguridad"

antes="$(cat "$SYSCFG_CMDLINE_FILE")"
ensure_required_kernel_params; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSCFG_CMDLINE_FILE")" == "$antes" ]] \
  && bien "repetir no cambia nada (idempotente)" || mal "la segunda pasada cambió algo (rc=$rc)"

# Uno ya puesto y otro con un valor DISTINTO: el distinto no cuenta como puesto.
printf '%s pcie_aspm=off nvme_core.default_ps_max_latency_us=5500\n' "$ORIGINAL" > "$SYSCFG_CMDLINE_FILE"
faltan="$(missing_kernel_params "$SYSCFG_CMDLINE_FILE" | tr '\n' ' ')"
[[ "$faltan" == "nvme_core.default_ps_max_latency_us=0 pcie_port_pm=off " ]] \
  && bien "un valor distinto no cuenta como puesto" || mal "faltan mal calculados: '$faltan'"
ensure_required_kernel_params >/dev/null
[[ "$(grep -o 'pcie_aspm=off' "$SYSCFG_CMDLINE_FILE" | wc -l | tr -d ' ')" == 1 ]] \
  && bien "no duplica el que ya estaba" || mal "duplicó pcie_aspm=off"

# Un prefijo no es el parámetro.
printf '%s xpcie_aspm=off\n' "$ORIGINAL" > "$SYSCFG_CMDLINE_FILE"
faltan="$(missing_kernel_params "$SYSCFG_CMDLINE_FILE")"
grep -qx 'pcie_aspm=off' <<< "$faltan" \
  && bien "compara por palabra completa" || mal "dio por bueno un prefijo"

echo "journal"

echo 'abc123' > "$SYSCFG_MACHINE_ID_FILE"
printf '[Journal]\nStorage=volatile\n#Compress=yes\n' > "$SYSCFG_JOURNALD_CONF"
journal_is_persistent && mal "lo da por persistente sin fichero" || bien "sin system.journal no es persistente"

ensure_persistent_journal
grep -q '^Storage=persistent$' "$SYSCFG_JOURNALD_DROPIN" && grep -q '^SystemMaxUse=200M$' "$SYSCFG_JOURNALD_DROPIN" \
  && bien "drop-in con Storage=persistent y tope" || mal "drop-in incorrecto"
grep -q '^#Storage=volatile$' "$SYSCFG_JOURNALD_CONF" && ! grep -q '^Storage=' "$SYSCFG_JOURNALD_CONF" \
  && bien "comenta el Storage=volatile del principal" || mal "el principal sigue mandando volatile"
[[ -d "$SYSCFG_JOURNAL_DIR" ]] && bien "crea /var/log/journal" || mal "no crea /var/log/journal"

antes="$(cat "$SYSCFG_JOURNALD_CONF" "$SYSCFG_JOURNALD_DROPIN")"
ensure_persistent_journal
[[ "$(cat "$SYSCFG_JOURNALD_CONF" "$SYSCFG_JOURNALD_DROPIN")" == "$antes" ]] \
  && bien "repetir no cambia nada (idempotente)" || mal "la segunda pasada cambió algo"

mkdir -p "$SYSCFG_JOURNAL_DIR/abc123" && touch "$SYSCFG_JOURNAL_DIR/abc123/system.journal"
journal_is_persistent && bien "con system.journal sí es persistente" || mal "no ve el system.journal"

echo
if [[ $fallos -gt 0 ]]; then
  echo "$fallos fallo(s)"
  exit 1
fi
echo "Todo bien"
