#!/usr/bin/env bash
# =============================================================================
# FuelManager Kiosk — configuración OBLIGATORIA del sistema
# -----------------------------------------------------------------------------
# Source'eable desde install-raspberry.sh, setup-system.sh y check-raspberry.sh.
#
# Lo que hay aquí no es una preferencia: sin ello la Raspberry se cuelga.
#
#   1. Tres parámetros del kernel que apagan el ahorro de energía del NVMe y
#      del PCIe. Los discos NVMe sin DRAM (el Fanxiang S501 de la flota) entran
#      en reposo profundo tras un rato sin uso y a veces no despiertan: el
#      disco desaparece, todo lo que lee o escribe se queda esperando y la
#      pantalla se queda negra. Desde fuera parece apagado. Pasó en junio al
#      clonar (memoria pi5-nvme-aspm-fanxiang) y el 28-09 y el 29-09 en
#      kiosk-cccccccc, que nunca los tuvo: tras actualizar el SO el 19-09
#      empezó a colgarse en reposo.
#   2. El journal persistente. Raspberry Pi OS lo trae volátil, y tras un
#      cuelgue o un apagón no queda ni una línea que diga qué pasó: lo de
#      kiosk-cccccccc hubo que deducirlo de los ficheros que RustDesk escribe
#      cada hora. Con tope de tamaño para no llenar el disco.
#
# 🔴 La app comprueba lo mismo en cada kiosko y lo manda en el ping
# (`system_health.config_checks`, src/main/requiredSystemConfig.ts). La lista
# de parámetros está escrita en los dos sitios y un test
# (requiredSystemConfig.unit.test.ts) falla si divergen.
#
# Requisitos del script que lo sourcee: nada para las funciones de lectura;
# log(), ok() y warn() para las ensure_* (que además exigen root).
#
# API expuesta:
#   REQUIRED_KERNEL_PARAMS        — array con los parámetros obligatorios.
#   missing_kernel_params FICHERO — imprime, uno por línea, los que faltan.
#   journal_is_persistent         — 0 si el journal está guardando en disco.
#   ensure_required_kernel_params — los añade a cmdline.txt (idempotente).
#   ensure_persistent_journal     — journal persistente con tope (idempotente).
#
# Las rutas se pueden cambiar por variable de entorno para los tests
# (scripts/test-system-config.sh).
# =============================================================================

REQUIRED_KERNEL_PARAMS=(
  nvme_core.default_ps_max_latency_us=0
  pcie_aspm=off
  pcie_port_pm=off
)

SYSCFG_CMDLINE_FILE="${SYSCFG_CMDLINE_FILE:-/boot/firmware/cmdline.txt}"
SYSCFG_JOURNALD_CONF="${SYSCFG_JOURNALD_CONF:-/etc/systemd/journald.conf}"
SYSCFG_JOURNALD_DROPIN="${SYSCFG_JOURNALD_DROPIN:-/etc/systemd/journald.conf.d/90-fuelmanager-persistent.conf}"
SYSCFG_JOURNAL_DIR="${SYSCFG_JOURNAL_DIR:-/var/log/journal}"
SYSCFG_MACHINE_ID_FILE="${SYSCFG_MACHINE_ID_FILE:-/etc/machine-id}"
SYSCFG_JOURNAL_MAX_USE="${SYSCFG_JOURNAL_MAX_USE:-200M}"

# Imprime los parámetros obligatorios que NO están en el fichero dado (una línea
# de cmdline: /proc/cmdline para lo que está activo, cmdline.txt para lo que
# entrará en el próximo arranque). Comparación por palabra completa.
missing_kernel_params() {
  local file="$1" param words
  words=" $(tr '\n' ' ' < "$file" 2>/dev/null || true) "
  for param in "${REQUIRED_KERNEL_PARAMS[@]}"; do
    [[ "$words" == *" $param "* ]] || echo "$param"
  done
}

# ¿Está journald escribiendo en disco AHORA? Se mira el efecto, no la
# configuración: el fichero del journal de esta máquina.
journal_is_persistent() {
  local mid
  mid="$(cat "$SYSCFG_MACHINE_ID_FILE" 2>/dev/null)"
  [[ -n "$mid" && -f "$SYSCFG_JOURNAL_DIR/$mid/system.journal" ]]
}

# Añade a cmdline.txt los parámetros que falten. cmdline.txt es UNA sola línea:
# un salto de línea de más y el kernel ignora todo lo que haya detrás.
# Devuelve 0 si no había nada que hacer y 10 si lo cambió (hace falta reiniciar).
ensure_required_kernel_params() {
  local file="$SYSCFG_CMDLINE_FILE" missing line
  if [[ ! -f "$file" ]]; then
    [[ -f /boot/cmdline.txt ]] && file=/boot/cmdline.txt || {
      warn "No encuentro cmdline.txt — no puedo poner los parámetros del NVMe"
      return 1
    }
  fi

  # Sin mapfile: los tests corren también en el bash 3.2 del Mac.
  missing="$(missing_kernel_params "$file" | tr '\n' ' ' | sed -E 's/ $//')"
  if [[ -z "$missing" ]]; then
    ok "Parámetros del NVMe/PCIe ya presentes en $file"
    return 0
  fi

  cp -p "$file" "$file.bak-$(date +%Y%m%d-%H%M%S)"
  line="$(tr '\n' ' ' < "$file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  # Fichero nuevo y `mv`: un corte de luz a medio escribir no puede dejar un
  # cmdline.txt a medias, que es una Pi que no arranca.
  printf '%s %s\n' "$line" "$missing" > "$file.tmp"
  mv -f "$file.tmp" "$file"
  sync
  ok "Añadidos a $file: $missing (hace falta reiniciar)"
  return 10
}

# Journal persistente con tope de tamaño, en un drop-in propio para no pelear
# con el journald.conf del sistema. Si el journald.conf trae `Storage=volatile`
# explícito (algunas imágenes lo traen) se comenta, porque el drop-in gana a la
# configuración principal pero conviene que nadie lea un valor que no manda.
ensure_persistent_journal() {
  local dir changed=0
  dir="$(dirname "$SYSCFG_JOURNALD_DROPIN")"
  local want
  want="$(printf '[Journal]\nStorage=persistent\nSystemMaxUse=%s\n' "$SYSCFG_JOURNAL_MAX_USE")"

  if [[ "$(cat "$SYSCFG_JOURNALD_DROPIN" 2>/dev/null)" != "$want" ]]; then
    mkdir -p "$dir"
    printf '%s\n' "$want" > "$SYSCFG_JOURNALD_DROPIN"
    changed=1
  fi
  if grep -qE '^[[:space:]]*Storage=' "$SYSCFG_JOURNALD_CONF" 2>/dev/null; then
    # Sin `sed -i`: GNU y BSD lo entienden distinto y los tests corren en Mac.
    sed -E 's/^([[:space:]]*Storage=)/#\1/' "$SYSCFG_JOURNALD_CONF" > "$SYSCFG_JOURNALD_CONF.tmp" \
      && cat "$SYSCFG_JOURNALD_CONF.tmp" > "$SYSCFG_JOURNALD_CONF"
    rm -f "$SYSCFG_JOURNALD_CONF.tmp"
    changed=1
  fi
  mkdir -p "$SYSCFG_JOURNAL_DIR"

  if [[ $changed -eq 0 ]]; then
    ok "Journal persistente ya configurado"
    return 0
  fi
  if [[ -z "${SYSCFG_NO_RESTART:-}" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-journald 2>/dev/null || true
    journalctl --flush 2>/dev/null || true
  fi
  ok "Journal persistente (tope $SYSCFG_JOURNAL_MAX_USE) en $SYSCFG_JOURNALD_DROPIN"
  return 0
}
