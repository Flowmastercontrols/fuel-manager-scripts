#!/usr/bin/env bash
#
# Agente de parches del sistema operativo del kiosko.
# Flowmastercontrols/fuel-manager-system#159 · cloud#450
#
# ## Por qué existe esto y no un `sudo` desde la app
#
# Porque la app NO PUEDE elevar privilegios. El proceso Electron corre con
# `no_new_privs=1` —lo pone Chromium— que se hereda por los hijos e impide que
# `sudo` escale a root. Y antes de que alguien lo descubriera, fallaba EN
# SILENCIO enseñando «OK, se reiniciará en ~60s» sin reiniciar nunca. Está
# documentado en `src/main/ipcMain.tsx`.
#
# Así que el reparto es el único que funciona, y resulta ser el más seguro:
#
#     app (sin privilegios)          root (este script, vía systemd)
#     ─────────────────────          ───────────────────────────────
#     escribe la orden     ──────▶   la lee, la VALIDA y decide
#     lee el resultado     ◀──────   escribe el resultado
#
# La app nunca gana privilegios: no hay entrada en `sudoers`, no hay setuid, no
# hay nada que heredar. El peor caso de una app comprometida es PEDIR algo, y
# quien decide es este script.
#
# ## 🔴 Las reglas que no se negocian
#
#  1. **Del fichero NO sale texto que acabe en un comando.** Se lee un JSON, se
#     saca `mode` y se compara contra un enum de cuatro valores. Nunca nombres
#     de paquete: `apt install <lo que llegue>` sería ejecución remota de código
#     como root.
#  2. **El reinicio no es un comando suelto.** Solo se reinicia si queda
#     `/var/run/reboot-required` después de instalar. No se expone un «reinicia
#     la Pi» de propósito general.
#  3. **Tope diario**, decidido AQUÍ y no configurable desde el cloud. Limita el
#     daño de un cloud comprometido: no puede dejar la flota en bucle de
#     reinicio.
#  4. **Nunca con un repostaje en curso.** La app deja una marca; si está, se
#     espera a la siguiente pasada.
#  5. **Una orden ya ejecutada no se repite y una vieja no se ejecuta.** Ni
#     replay ni disparos tardíos.
#
# Lo que NO cubre: el acceso físico a la Raspberry. Quien la tenga en la mano no
# necesita nada de esto (hoja S1–S42).
#
# ## Uso
#
#   fmc-os-update.sh            # una pasada; es lo que llama el timer
#   fmc-os-update.sh --dry-run  # dice qué haría y no toca nada
#
set -euo pipefail

# PATH fijo y absoluto: este script corre como root y no hereda nada de nadie.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l

# ── Dónde vive todo ─────────────────────────────────────────────────────────
#
# La orden la escribe la app, así que vive en SU directorio. El estado lo
# escribe este script y vive en /var/lib, donde la app no puede tocarlo: si la
# app pudiera editar el registro de órdenes ejecutadas, el tope diario y la
# protección contra repeticiones no valdrían nada.
APP_USER="${FMC_APP_USER:-fuelmanager}"
APP_HOME="$( (getent passwd "$APP_USER" 2>/dev/null || true) | cut -d: -f6)"
APP_DIR="${FMC_APP_DIR:-$APP_HOME/.local/share/FuelManager}"
REQUEST="$APP_DIR/os-update-request.json"
RESULT="$APP_DIR/os-update-result.json"
BUSY="$APP_DIR/refuelling.lock"

# Configurable solo para poder PROBARLO fuera de una Raspberry. En un
# kiosko siempre es /var/lib, donde la app no puede escribir: si pudiera
# editar el registro de ordenes hechas, el tope diario y la proteccion
# contra repeticiones no valdrian nada.
STATE_DIR="${FMC_STATE_DIR:-/var/lib/fmc-os-update}"
DONE_LOG="$STATE_DIR/done.log"
RUN_LOG="$STATE_DIR/agent.log"

MAX_PER_DAY="${FMC_MAX_PER_DAY:-3}"
MAX_ORDER_AGE_HOURS="${FMC_MAX_ORDER_AGE_HOURS:-48}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$STATE_DIR"
touch "$DONE_LOG"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$RUN_LOG" >&2; }

# El resultado que leerá la app. Se escribe de forma atómica y con el dueño
# correcto: si no, la app no podría leerlo y se quedaría sin saber qué pasó.
escribir_resultado() {
  local estado="$1" progreso="${2:-}" error="${3:-}"
  local tmp="$RESULT.tmp"
  {
    printf '{"id":%s,"state":"%s"' "$(json_str "$ORDER_ID")" "$estado"
    [[ -n "$progreso" ]] && printf ',"progress":%d' "$progreso"
    [[ -n "$error" ]] && printf ',"error":%s' "$(json_str "$error")"
    printf ',"at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  chown "$APP_USER": "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$RESULT"
}

json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$/"/'; }

# Saca un campo de primer nivel del JSON. A propósito con `grep`/`sed` y no con
# un parser: lo que se extrae se compara después contra un enum cerrado, y la
# única forma de que algo de aquí haga daño sería que acabara en un comando.
# No acaba.
campo() {
  # 🔴 El `|| true` no es cosmetico. Con `set -o pipefail`, un grep que no
  # encuentra nada devuelve 1, la sustitucion de comandos falla y `set -e` mata
  # el agente EN SILENCIO: un fichero de orden a medias dejaria de parchear la
  # Raspberry sin dejar ni una linea de por que. Lo cazo una prueba con un
  # fichero sin `id`.
  { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$REQUEST" 2>/dev/null || true; } \
    | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# `date -d` es GNU y `date -j -f` es BSD. En un kiosko siempre es el primero; el
# segundo esta para poder probar esto en un Mac. Si ninguno sabe leer la fecha
# se DICE, en vez de dejar la caducidad apagada sin que se note.
epoch_de() {
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || echo 0
}

salir_sin_nada() { log "$1"; exit 0; }

# ── 1 · ¿Hay una orden? ─────────────────────────────────────────────────────

[[ -f "$REQUEST" ]] || salir_sin_nada "sin orden pendiente"

# 🔴 El fichero tiene que ser del usuario de la app. Si lo escribió otro, no es
# una orden nuestra y no se mira siquiera.
# `stat -c` es GNU y `stat -f` es BSD. En un kiosko siempre es el primero;
# el segundo esta para poder probar este script en un Mac, que es donde se
# escribe. Si ninguno contesta, el dueno es desconocido y se descarta.
DUENO="$(stat -c %U "$REQUEST" 2>/dev/null || stat -f %Su "$REQUEST" 2>/dev/null || echo '?')"
if [[ "$DUENO" != "$APP_USER" && "$DUENO" != "root" ]]; then
  salir_sin_nada "orden descartada: la escribio '$DUENO', no '$APP_USER'"
fi

ORDER_ID="$(campo id)"
MODE="$(campo mode)"
REQUESTED_AT="$(campo requested_at)"

[[ -n "$ORDER_ID" ]] || salir_sin_nada "orden sin id: descartada"

# ── 2 · ¿Es válida? ─────────────────────────────────────────────────────────

# 🔴 El enum cerrado. Todo lo demás se descarta entero.
case "$MODE" in
  security|kernel|all) ;;
  *) log "modo no reconocido: descartada"; escribir_resultado failed '' "modo no reconocido"; rm -f "$REQUEST"; exit 0 ;;
esac

# Ya ejecutada: ni replay ni dobles.
if grep -qxF "$ORDER_ID" "$DONE_LOG"; then
  salir_sin_nada "orden $ORDER_ID ya ejecutada"
fi

# Vieja: no se dispara tarde.
if [[ -n "$REQUESTED_AT" ]]; then
  PEDIDA_TS="$(epoch_de "$REQUESTED_AT")"
  AHORA_TS="$(date -u +%s)"
  if (( PEDIDA_TS == 0 )); then
    log "no se pudo leer la fecha de la orden ('$REQUESTED_AT'): la caducidad no se aplica"
  fi
  if (( PEDIDA_TS > 0 && AHORA_TS - PEDIDA_TS > MAX_ORDER_AGE_HOURS * 3600 )); then
    log "orden $ORDER_ID caducada ($MAX_ORDER_AGE_HOURS h)"
    escribir_resultado failed '' "la orden caduco antes de poder ejecutarse"
    rm -f "$REQUEST"
    exit 0
  fi
fi

# Tope diario. Decidido aqui y no configurable desde el cloud.
HOY="$(date -u +%Y-%m-%d)"
HECHAS_HOY="$(grep -c "^$HOY " "$RUN_LOG" 2>/dev/null || true)"
if (( ${HECHAS_HOY:-0} >= MAX_PER_DAY )); then
  salir_sin_nada "tope diario alcanzado ($MAX_PER_DAY): no se ejecuta"
fi

# Repostaje en curso: se espera a la siguiente pasada. No es seguridad, es no
# cortarle el suministro a nadie.
if [[ -f "$BUSY" ]]; then
  salir_sin_nada "repostaje en curso: se reintenta en la siguiente pasada"
fi

if (( DRY_RUN )); then
  log "DRY RUN: ejecutaria la orden $ORDER_ID en modo $MODE"
  exit 0
fi

# ── 3 · Ejecutar ────────────────────────────────────────────────────────────

log "$HOY ejecutando orden $ORDER_ID modo=$MODE"
escribir_resultado downloading 10

if ! apt-get update -qq >>"$RUN_LOG" 2>&1; then
  log "apt-get update fallo"
  escribir_resultado failed '' "no se pudo refrescar el indice de paquetes"
  exit 0
fi

escribir_resultado installing 40

# 🔴 Aqui esta el unico punto donde el modo decide algo, y decide entre tres
# comandos ESCRITOS EN ESTE FICHERO. No se compone ninguno con texto de fuera.
set +e
case "$MODE" in
  security)
    unattended-upgrade -v >>"$RUN_LOG" 2>&1
    RC=$?
    ;;
  kernel)
    apt-get install -y --only-upgrade \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      linux-image-rpi-v8 linux-image-rpi-2712 linux-headers-rpi-v8 linux-headers-rpi-2712 \
      linux-image-amd64 linux-image-aws linux-headers-aws >>"$RUN_LOG" 2>&1
    RC=$?
    ;;
  all)
    apt-get upgrade -y \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold >>"$RUN_LOG" 2>&1
    RC=$?
    ;;
esac
set -e

# Marcarla como hecha ANTES de reiniciar: si no, un reinicio la dejaria sin
# marcar y la siguiente pasada la ejecutaria otra vez.
printf '%s\n' "$ORDER_ID" >> "$DONE_LOG"
rm -f "$REQUEST"

if (( RC != 0 )); then
  log "la instalacion fallo (rc=$RC)"
  escribir_resultado failed '' "apt termino con codigo $RC; ver $RUN_LOG"
  exit 0
fi

# ── 4 · ¿Hace falta reiniciar? ──────────────────────────────────────────────

if [[ ! -e /var/run/reboot-required ]]; then
  log "orden $ORDER_ID terminada sin reinicio"
  escribir_resultado done 100
  exit 0
fi

# Ultima comprobacion justo antes: entre que empezo el apt y ahora puede haber
# entrado alguien a repostar.
if [[ -f "$BUSY" ]]; then
  log "hace falta reiniciar pero hay un repostaje en curso: se deja pendiente"
  escribir_resultado reboot_pending 90
  exit 0
fi

log "orden $ORDER_ID terminada; reiniciando"
escribir_resultado reboot_pending 95
sync
systemctl reboot
