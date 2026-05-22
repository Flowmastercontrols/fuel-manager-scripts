#!/usr/bin/env bash
# =============================================================================
# FuelManager Kiosk — Raspberry Pi 5 Install Script (PRODUCTION)
# -----------------------------------------------------------------------------
# Configures a fresh Raspberry Pi OS (Bookworm or later) to run the compiled
# FuelManager AppImage.
#
# This script does NOT install build tools, Node.js, or project sources —
# for that, use dev-install-raspberry.sh instead.
#
# What it does:
#   1. Installs RUNTIME system libraries needed by the AppImage
#   2. Enables I2C, UART and SPI
#   3. Configures /boot/firmware/config.txt with UART overlays
#   4. Adds user to required groups (dialout, gpio, input, etc.)
#   5. Creates udev rule for the USB HID card reader
#   6. Enables Bluetooth service
#   7. Grants BLE capabilities to the AppImage (if found)
#
# Usage:
#   sudo bash install-raspberry.sh path/to/FuelManager.AppImage  (REQUIRED)
#
# After running, reboot once and then run check-raspberry.sh
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

# ───────────────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}==>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
fail()  { echo -e "${RED}✗${NC}  $*"; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "This script must be run with sudo. Try: sudo bash $0"
  fi
}

TARGET_USER="${SUDO_USER:-$USER}"
APPIMAGE_PATH="${1:-}"
TAILSCALE_AUTHKEY_ARG="${2:-}"   # opcional: segundo positional arg (puede ser una key tskey-auth-...)
TAILSCALE_PERSISTED_KEY_PATH="/etc/flowmaster/tailscale.key"
FUELMANAGER_USERNAME="fuelmanager"

# ───────────────────────────────────────────────────────────────────────────
# Preflight
# ───────────────────────────────────────────────────────────────────────────

require_root

log "FuelManager Kiosk — production install (user: $TARGET_USER)"

# ───────────────────────────────────────────────────────────────────────────
# 0c. Asegurar que existe el usuario 'fuelmanager'
# -----------------------------------------------------------------------------
# El ACL de Tailscale autoriza SSH al kiosko sólo con `users: ["fuelmanager"]`,
# así que el equipo de soporte SIEMPRE entra como `fuelmanager`. En la mayoría
# de Pis recién flasheadas ese es directamente el usuario por defecto del
# imager. Pero hay Pis (típicamente de desarrollo) donde el usuario es otro
# (ej. `lucas`); en esos casos creamos `fuelmanager` para que la ACL siga
# funcionando.
#
# Si lo creamos: lo añadimos a los grupos hardware estándar + sudo, y pedimos
# password interactivamente. El password es necesario para que `sudo X` desde
# una sesión Tailscale-SSH funcione (Tailscale autentica la sesión sin pass,
# pero `sudo` sí pide pass — defensa en profundidad).
#
# Si NO hay TTY (ej. invocación desde DangerZone), se omite la creación con
# un warning. Es esperable: en ese modo el kiosko ya está montado y el usuario
# fuelmanager ya debería existir.
# ───────────────────────────────────────────────────────────────────────────

ensure_fuelmanager_user() {
  if id "$FUELMANAGER_USERNAME" >/dev/null 2>&1; then
    ok "Usuario '$FUELMANAGER_USERNAME' ya existe (no se toca)"
    return 0
  fi

  if [[ ! -e /dev/tty ]]; then
    warn "Usuario '$FUELMANAGER_USERNAME' no existe y no hay TTY — SE OMITE creación."
    warn "  El equipo de soporte no podrá hacer SSH a este Pi hasta que se cree."
    return 0
  fi

  log "Usuario '$FUELMANAGER_USERNAME' no existe — creándolo..."
  useradd -m -s /bin/bash "$FUELMANAGER_USERNAME"

  # Grupos hardware estándar (mismo set que para TARGET_USER más abajo) + sudo
  for g in dialout gpio input video audio i2c spi plugdev sudo; do
    if getent group "$g" >/dev/null 2>&1; then
      usermod -aG "$g" "$FUELMANAGER_USERNAME"
    fi
  done
  ok "Usuario '$FUELMANAGER_USERNAME' creado + añadido a grupos hardware + sudo"

  echo
  echo "════════════════════════════════════════════════════════════════"
  echo " Configura el password para el usuario '$FUELMANAGER_USERNAME'"
  echo "════════════════════════════════════════════════════════════════"
  echo " Este password se pide al hacer 'sudo' desde una sesión SSH del"
  echo " equipo de soporte. Guárdalo en tu gestor de contraseñas."
  echo
  if passwd "$FUELMANAGER_USERNAME" < /dev/tty; then
    ok "Password de '$FUELMANAGER_USERNAME' establecida"
  else
    warn "Falló el establecimiento del password — '$FUELMANAGER_USERNAME' existe pero sin password."
    warn "  'sudo' no funcionará para ese usuario hasta que ejecutes: sudo passwd $FUELMANAGER_USERNAME"
  fi
}

ensure_fuelmanager_user

# ───────────────────────────────────────────────────────────────────────────
# 0a. Validar que se pasó un AppImage como argumento
# ───────────────────────────────────────────────────────────────────────────

if [[ -z "$APPIMAGE_PATH" ]]; then
  fail "Falta el path del AppImage como argumento.

Uso:
  sudo bash $0 /ruta/a/FuelManager-X.X.X-ENV.AppImage

Ejemplo:
  cd ~/Documents/fuel-manager-system
  sudo bash scripts/install-raspberry.sh release/build/FuelManager-1.9.36-alpha.2-FEATURES.AppImage

Esto evita que el script instale silenciosamente una versión antigua o
incorrecta. Si no sabes qué AppImage usar, lista los disponibles:
  ls -la release/build/*.AppImage 2>/dev/null
  ls -la ~/Downloads/*.AppImage 2>/dev/null"
fi

if [[ ! -f "$APPIMAGE_PATH" ]]; then
  fail "El archivo no existe: $APPIMAGE_PATH"
fi

# Mostrar versión que estamos a punto de instalar
APPIMAGE_BASENAME=$(basename "$APPIMAGE_PATH")
APPIMAGE_SIZE_MB=$(du -m "$APPIMAGE_PATH" | cut -f1)
log "AppImage seleccionada: $APPIMAGE_BASENAME (${APPIMAGE_SIZE_MB} MB)"

# ───────────────────────────────────────────────────────────────────────────
# 0b. Matar procesos en ejecución y limpiar restos del .deb antiguo
# ───────────────────────────────────────────────────────────────────────────

log "Matando procesos del kiosko en ejecución..."
pkill -9 -f "com.fuelmastercontrol" 2>/dev/null || true
pkill -9 -f "Fuel Management"        2>/dev/null || true
sleep 1

if dpkg -l com.fuelmastercontrol.kiosko 2>/dev/null | grep -q "^ii"; then
  log "Detectado .deb antiguo registrado en apt — desinstalando..."
  apt remove -y com.fuelmastercontrol.kiosko >/dev/null 2>&1 || true
  ok ".deb antiguo desinstalado"
fi

# Limpieza manual de restos (apt remove no siempre lo deja todo limpio,
# y a veces el .deb no estuvo registrado pero los archivos sí están).
LEGACY_PATHS=(
  "/opt/FuelManager"
  "/etc/xdg/autostart/fuelmanager.desktop"   # autostart system-wide del .deb
  "/etc/ld.so.conf.d/fuelmanager.conf"       # ld config del .deb
)
LEGACY_FOUND=0
for p in "${LEGACY_PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    rm -rf "$p"
    LEGACY_FOUND=1
  fi
done
if [[ $LEGACY_FOUND -eq 1 ]]; then
  ldconfig
  ok "Restos del .deb antiguo eliminados"
fi

if [[ ! -f /etc/rpi-issue ]] && [[ ! -f /etc/os-release ]]; then
  warn "This doesn't look like a Raspberry Pi. Continuing anyway..."
fi

# ───────────────────────────────────────────────────────────────────────────
# Tested-system preflight
# -----------------------------------------------------------------------------
# Compare the current hardware + OS against the reference the kiosk has been
# verified on (scripts/tested-system.conf). Any mismatch is a warning, not a
# fatal error — install continues but the operator sees what differs.
# ───────────────────────────────────────────────────────────────────────────

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TESTED_CONF="$SCRIPT_DIR/tested-system.conf"

if [[ -f "$TESTED_CONF" ]]; then
  # shellcheck disable=SC1090
  . "$TESTED_CONF"

  log "Verifying system against tested reference..."

  MISMATCH=0

  if [[ -f /proc/device-tree/model ]]; then
    MODEL=$(tr -d '\0' < /proc/device-tree/model)
    if echo "$MODEL" | grep -qi "$EXPECTED_MODEL"; then
      ok "Model: $MODEL"
    else
      warn "Model mismatch — tested on '$EXPECTED_MODEL', got '$MODEL'"
      MISMATCH=1
    fi
  fi

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${VERSION_CODENAME:-}" == "$EXPECTED_OS_CODENAME" && "${VERSION_ID:-}" == "$EXPECTED_OS_VERSION_ID" ]]; then
      ok "OS: $PRETTY_NAME"
    else
      warn "OS mismatch — tested on Debian ${EXPECTED_OS_VERSION_ID} (${EXPECTED_OS_CODENAME}), got ${VERSION_ID:-?} (${VERSION_CODENAME:-?})"
      MISMATCH=1
    fi
  fi

  if [[ -f /etc/rpi-issue ]]; then
    RPI_IMAGE_DATE=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' /etc/rpi-issue | head -n1)
    if [[ "$RPI_IMAGE_DATE" == "$EXPECTED_RPI_IMAGE_DATE" ]]; then
      ok "RPi OS image: $RPI_IMAGE_DATE"
    else
      warn "RPi OS image mismatch — tested on $EXPECTED_RPI_IMAGE_DATE, got ${RPI_IMAGE_DATE:-unknown}"
      MISMATCH=1
    fi
  fi

  KERNEL=$(uname -r)
  if [[ "$KERNEL" == ${EXPECTED_KERNEL_MAJOR_MINOR}.* ]]; then
    ok "Kernel: $KERNEL"
  else
    warn "Kernel mismatch — tested on ${EXPECTED_KERNEL_MAJOR_MINOR}.x, got $KERNEL"
    MISMATCH=1
  fi

  if [[ $MISMATCH -ne 0 ]]; then
    echo
    warn "One or more components differ from the tested reference."
    warn "The kiosk may still run, but this configuration is UNVERIFIED."
    warn "For a supported setup, flash Raspberry Pi OS ${EXPECTED_OS_CODENAME} (${EXPECTED_RPI_IMAGE_DATE}) on a ${EXPECTED_MODEL}."
    echo
    if [[ -t 0 ]]; then
      read -r -p "Continue anyway? [y/N] " ANSWER
      case "${ANSWER,,}" in
        y|yes) : ;;
        *) fail "Aborted by user." ;;
      esac
    else
      warn "Non-interactive install — continuing despite mismatch."
    fi
  fi
else
  warn "tested-system.conf not found — skipping system-version check"
fi

# ───────────────────────────────────────────────────────────────────────────
# 1. Runtime system libraries
# ───────────────────────────────────────────────────────────────────────────

log "Installing runtime system libraries..."

apt-get update -qq

apt-get install -y -qq \
  libusb-1.0-0 \
  libudev1 \
  libsqlite3-0 \
  libbluetooth3 \
  libgpiod2 \
  bluez \
  bluetooth \
  libfuse2 \
  i2c-tools \
  > /dev/null

ok "Runtime libraries installed"

# ───────────────────────────────────────────────────────────────────────────
# 2. Enable kernel interfaces
# ───────────────────────────────────────────────────────────────────────────

log "Enabling I2C, SPI and UART..."

if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_i2c 0         || warn "do_i2c failed"
  raspi-config nonint do_spi 0         || warn "do_spi failed"
  raspi-config nonint do_serial_hw 0   || warn "do_serial_hw failed"
  raspi-config nonint do_serial_cons 1 || warn "do_serial_cons failed"
  ok "Kernel interfaces enabled"
else
  warn "raspi-config not found — enable I2C/SPI/UART manually"
fi

# ───────────────────────────────────────────────────────────────────────────
# 3. UART overlays
# ───────────────────────────────────────────────────────────────────────────

BOOT_CONFIG=/boot/firmware/config.txt
[[ -f /boot/config.txt && ! -f $BOOT_CONFIG ]] && BOOT_CONFIG=/boot/config.txt

log "Configuring UART overlays in $BOOT_CONFIG..."

MARKER="# === FuelManager UART overlays ==="

if grep -q "$MARKER" "$BOOT_CONFIG" 2>/dev/null; then
  ok "UART overlays already present"
else
  cat >> "$BOOT_CONFIG" <<'EOF'

# === FuelManager UART overlays ===
enable_uart=1
dtparam=uart0=on
dtoverlay=uart0
dtoverlay=uart4,txd8,txd9
dtoverlay=uart5,txd_pin=12,rxd_pin=13
dtparam=i2c_arm=on
dtparam=i2c_arm_baudrate=100000
EOF
  ok "UART overlays added (reboot required)"
fi

# ───────────────────────────────────────────────────────────────────────────
# 4. User groups
# ───────────────────────────────────────────────────────────────────────────

log "Adding user '$TARGET_USER' to hardware groups..."

for group in dialout gpio input video audio i2c spi plugdev; do
  if getent group "$group" >/dev/null 2>&1; then
    usermod -aG "$group" "$TARGET_USER"
  fi
done

ok "User groups configured (logout/login required)"

# ───────────────────────────────────────────────────────────────────────────
# 5. udev rules
# ───────────────────────────────────────────────────────────────────────────

UDEV_RULE=/etc/udev/rules.d/99-fuelmanager.rules

log "Installing udev rules for USB HID card reader..."

cat > "$UDEV_RULE" <<'EOF'
# Syncotek SK-288-K001 — USB HID card reader
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="23d8", ATTRS{idProduct}=="0285", MODE="0666"

# Prolific PL2303 — USB-to-serial (RFID reader, may be used for MTR_PCB)
SUBSYSTEM=="tty", ATTRS{idVendor}=="067b", ATTRS{idProduct}=="2303", MODE="0666", GROUP="dialout"

# Generic USB CDC ACM serial
SUBSYSTEM=="tty", KERNEL=="ttyACM[0-9]*", MODE="0666", GROUP="dialout"
EOF

udevadm control --reload-rules
udevadm trigger

ok "udev rules installed"

# ───────────────────────────────────────────────────────────────────────────
# 6. Bluetooth service
# ───────────────────────────────────────────────────────────────────────────

log "Enabling Bluetooth service..."
systemctl enable bluetooth >/dev/null 2>&1

# Release HCI control from bluetoothd so bleno can use it for BLE advertising.
# Without this override, bluetoothd holds the HCI socket exclusively and bleno
# gets 'unauthorized' state — the BLE beacon never starts.
mkdir -p /etc/systemd/system/bluetooth.service.d
cat > /etc/systemd/system/bluetooth.service.d/fuelmanager.conf <<'BTOVERRIDE'
[Service]
ExecStart=
ExecStart=/usr/libexec/bluetooth/bluetoothd --noplugin=sap --experimental
BTOVERRIDE

systemctl daemon-reload
systemctl restart bluetooth >/dev/null 2>&1 || systemctl start bluetooth >/dev/null 2>&1
ok "Bluetooth service running (BLE peripheral mode enabled)"

# ───────────────────────────────────────────────────────────────────────────
# Fix /dev/shm permissions (required by Chromium renderer in Electron)
# ───────────────────────────────────────────────────────────────────────────

log "Fixing /dev/shm permissions for Electron/Chromium..."
chmod 1777 /dev/shm

# Persist across reboots via systemd tmpfiles.d
cat > /etc/tmpfiles.d/99-fuelmanager-shm.conf <<'EOF'
# FuelManager — Chromium renderer needs writable /dev/shm
d /dev/shm 1777 root root -
EOF

ok "/dev/shm permissions set to 1777 (and persisted via tmpfiles.d)"

# ───────────────────────────────────────────────────────────────────────────
# 7. BLE capabilities on AppImage
# ───────────────────────────────────────────────────────────────────────────

log "Instalando AppImage explícita: $APPIMAGE_PATH"

install_appimage() {
  local appimage="$1"
  # ESTRATEGIA (Option B):
  # - Conservamos el AppImage como blob en disco para que electron-updater
  #   lo pueda reemplazar al hacer un update remoto.
  # - PERO ejecutamos el binario interno extraído. Razón: en Pi 5,
  #   AppImage + sudo (root) crashea con "Bus error" por incompatibilidad
  #   FUSE/root en libfuse2. Sin sudo, AppImage funciona, pero entonces
  #   bleno (BLE peripheral) no tiene cap_net_raw y falla.
  # - Setcap al BINARIO INTERNO extraído SÍ se hereda (no hay FUSE de por
  #   medio). El binario interno corre como usuario normal, sin sudo,
  #   con BLE funcional.
  local install_dir="/home/$TARGET_USER/.local/share/FuelManager"
  local installed_appimage="$install_dir/FuelManager.AppImage"
  local extract_dir="$install_dir/extracted"

  log "Installing $appimage to $install_dir/"

  # 1. Clean previous installation
  if [[ -d /opt/FuelManager ]]; then
    log "Removing legacy /opt/FuelManager installation..."
    rm -rf /opt/FuelManager
  fi
  rm -rf "$install_dir"
  mkdir -p "$install_dir"

  # 2. Copy the AppImage (electron-updater needs this file in place to be
  #    able to replace it during remote updates).
  cp "$appimage" "$installed_appimage"
  chmod +x "$installed_appimage"
  ok "AppImage copied: $installed_appimage"

  # 3. Extract the AppImage to a stable directory so we can:
  #    - Run the inner binary directly (no FUSE, no sudo).
  #    - Apply setcap to the inner binary (capability inherited correctly
  #      because it's a real ELF on disk, not behind a FUSE mount).
  log "Extracting AppImage to $extract_dir/ ..."
  pushd "$install_dir" >/dev/null
  "$installed_appimage" --appimage-extract >/dev/null
  rm -rf "$extract_dir"
  mv squashfs-root "$extract_dir"
  popd >/dev/null
  ok "AppImage extracted to: $extract_dir"

  # 4. Locate the inner Electron binary inside the extracted tree.
  local inner_bin
  inner_bin=$(find "$extract_dir" -maxdepth 2 -type f -executable \
    \( -name "com.fuelmastercontrol*" -o -name "fuelmanager*" -o -name "FuelManager*" -o -name "electron" \) \
    -not -name "*.so*" -not -name "AppRun*" -not -name "chrome-sandbox" -not -name "chrome_crashpad_handler" \
    2>/dev/null | head -1)

  if [[ -z "$inner_bin" || ! -x "$inner_bin" ]]; then
    fail "Could not find inner Electron binary inside $extract_dir"
  fi
  ok "Inner binary: $inner_bin"

  # 5. setcap on the inner binary. THIS is what makes BLE work — the inner
  #    binary IS a normal ELF on disk (no FUSE), so cap_net_raw is
  #    honoured by the kernel.
  setcap cap_net_raw,cap_net_admin+eip "$inner_bin"
  ok "setcap applied to inner binary (BLE will work without sudo)"

  # 5b. Register extract_dir in /etc/ld.so.conf.d/ so ld.so finds the
  #     Electron-bundled .so files (libffmpeg.so, libEGL.so, libnode.so, etc.).
  #     IMPORTANTE: cuando el binario tiene capabilities (cap_net_raw), el
  #     kernel pone AT_SECURE=1 al ejecutarlo, y ld.so IGNORA LD_LIBRARY_PATH
  #     por seguridad. Sin esta entrada en ld.so.conf.d, el binario crashea
  #     con "libffmpeg.so: cannot open shared object file" porque no encuentra
  #     sus propias librerías co-ubicadas.
  #
  #     El path es estable (~/.local/share/FuelManager/extracted/) y NO cambia
  #     entre re-extracciones por electron-updater, así que esto solo se
  #     necesita aplicar una vez por instalación.
  echo "$extract_dir" > /etc/ld.so.conf.d/fuelmanager.conf
  ldconfig
  ok "Library path registered: /etc/ld.so.conf.d/fuelmanager.conf"

  # 6. Sudoers: dos bloques de NOPASSWD muy acotados.
  #
  #    a) setcap al binario interno extraído del AppImage. Necesario porque
  #       el launcher re-extrae tras cada update remoto y debe re-aplicar
  #       capabilities (operación que requiere root).
  #
  #    b) Ejecutar los scripts de mantenimiento (setup-system.sh e
  #       install-raspberry.sh) cuando se disparan desde el botón de
  #       DangerZone → System Scripts dentro del kiosko. El handler del
  #       kiosko los descarga del repo público a /tmp/fuel-*.sh y los
  #       lanza con `sudo -n` — esa entrada permite que no pidan password.
  #
  #    Scope estrictamente acotado: comandos y paths específicos. NO se
  #    abre `bash` libre, ni se permite ejecutar el AppImage como root.
  local sudoers_file=/etc/sudoers.d/fuelmanager
  cat > "$sudoers_file" <<EOF
# Permite a $TARGET_USER aplicar setcap al binario interno extraído del
# FuelManager. Necesario para que el launcher pueda re-aplicar setcap
# tras cada update remoto (electron-updater reemplaza el AppImage; el
# launcher detecta el cambio, re-extrae, y necesita re-setcap).
#
# Adicionalmente, permite ejecutar los scripts de mantenimiento del
# sistema desde el propio kiosko (DangerZone → System Scripts). Los
# scripts viven en /tmp/fuel-*.sh — los descarga el handler IPC del
# repo público fuel-manager-scripts en cada invocación.
#
# Scope estrictamente limitado a estos comandos + paths concretos.
# Generado por install-raspberry.sh — NO EDITAR a mano.
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/setcap cap_net_raw\\,cap_net_admin+eip $inner_bin
$TARGET_USER ALL=(root) NOPASSWD: /bin/bash /tmp/fuel-setup-system.sh
$TARGET_USER ALL=(root) NOPASSWD: /bin/bash /tmp/fuel-install-raspberry.sh *
EOF
  chmod 440 "$sudoers_file"

  if visudo -cf "$sudoers_file" >/dev/null 2>&1; then
    ok "Sudoers entry (setcap + system scripts): $sudoers_file"
  else
    rm -f "$sudoers_file"
    fail "Sudoers entry inválida — abortando para no romper sudo"
  fi

  # 7. Launcher: detecta si el AppImage fue actualizada por electron-updater
  #    (mtime newer than extracted dir), en cuyo caso re-extrae y re-setcap.
  #    Ejecuta el binario interno directamente, sin sudo, sin FUSE.
  local launcher=/usr/local/bin/fuelmanager
  local inner_bin_relpath="${inner_bin#$extract_dir/}"
  cat > "$launcher" <<EOF
#!/bin/bash
# FuelManager Kiosk launcher (auto-generated by install-raspberry.sh).
#
# Estrategia: AppImage extraída + setcap al binario interno = BLE funciona
# sin sudo en runtime. La AppImage queda en disco para que electron-updater
# pueda reemplazarla; este launcher detecta cambios (mtime) y re-extrae +
# re-aplica setcap antes de cada arranque cuando hace falta.

set -eu

APPIMAGE="\$HOME/.local/share/FuelManager/FuelManager.AppImage"
EXTRACT_DIR="\$HOME/.local/share/FuelManager/extracted"
INNER_BIN_RELPATH="$inner_bin_relpath"
INNER_BIN="\$EXTRACT_DIR/\$INNER_BIN_RELPATH"

needs_extract=0
if [[ ! -d "\$EXTRACT_DIR" ]] || [[ ! -x "\$INNER_BIN" ]]; then
  needs_extract=1
elif [[ "\$APPIMAGE" -nt "\$INNER_BIN" ]]; then
  needs_extract=1
fi

if [[ \$needs_extract -eq 1 ]]; then
  echo "[fuelmanager] AppImage es más reciente que la extracción cacheada — re-extrayendo..."
  rm -rf "\$EXTRACT_DIR"
  cd "\$(dirname "\$EXTRACT_DIR")"
  "\$APPIMAGE" --appimage-extract >/dev/null
  mv squashfs-root extracted

  # Re-aplicar setcap (sudoers permite ESTE comando concreto sin password)
  if [[ -x "\$INNER_BIN" ]]; then
    sudo /usr/sbin/setcap cap_net_raw,cap_net_admin+eip "\$INNER_BIN" || \\
      echo "[fuelmanager] AVISO: setcap falló — BLE puede no funcionar"
  else
    echo "[fuelmanager] ERROR: binario interno no encontrado tras re-extraer: \$INNER_BIN"
    exit 1
  fi
fi

# Exportar APPIMAGE para que electron-updater sepa que estamos en un AppImage
# (aunque técnicamente ejecutemos el binario interno extraído). Apunta al
# .AppImage en disco para que electron-updater pueda reemplazarlo cuando
# llegue un update remoto. El IPC install-update del kiosko se encarga de
# copiar el binario descargado sobre este path y relanzar vía este launcher.
export APPIMAGE="\$APPIMAGE"

cd "\$EXTRACT_DIR"
exec "\$INNER_BIN" --no-sandbox "\$@"
EOF
  chmod +x "$launcher"
  ok "Launcher (sin sudo, ejecuta binario interno extraído): $launcher"

  # 5. Create a .desktop entry so it appears in the apps menu AND can be
  #    used by autostart mechanisms.
  local desktop_file=/usr/share/applications/fuelmanager.desktop
  cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=FuelManager Kiosk
Comment=Fuel Management System kiosk
Exec=/usr/local/bin/fuelmanager
Icon=$installed_appimage
Type=Application
Categories=Utility;Application;
Terminal=false
EOF
  ok "Desktop entry created: $desktop_file"

  # 6. Autostart on login — works for Wayfire (Pi OS Bookworm default) and
  #    fallback X11 sessions. Wayfire reads ~/.config/wayfire.ini autostart
  #    sections, but the standard XDG autostart works for both.
  local autostart_dir="/home/$TARGET_USER/.config/autostart"
  mkdir -p "$autostart_dir"
  cat > "$autostart_dir/fuelmanager.desktop" <<EOF
[Desktop Entry]
Name=FuelManager Kiosk
Comment=Auto-launch the kiosk at login
Exec=/usr/local/bin/fuelmanager
Type=Application
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  chown -R "$TARGET_USER":"$TARGET_USER" "$autostart_dir"
  ok "Autostart entry: $autostart_dir/fuelmanager.desktop"

  # 8. Ownership — install_dir y todo extracted/ pertenecen al usuario.
  #    Esencial: electron-updater debe poder escribir el AppImage, y el
  #    binario interno extraído es ejecutado por el usuario directamente.
  chown -R "$TARGET_USER":"$TARGET_USER" "$install_dir"
  # Re-aplicar setcap al binario interno (chown -R borra capabilities)
  setcap cap_net_raw,cap_net_admin+eip "$inner_bin"
  # Defensa en profundidad: setcap también al wrapper AppImage por si en
  # el futuro alguien lo ejecuta directo (no se hereda al inner via FUSE,
  # pero no daña).
  setcap cap_net_raw,cap_net_admin+eip "$installed_appimage" 2>/dev/null || true
}

# Instalar la AppImage que el usuario pasó explícitamente. No hay
# auto-detección — eso era una fuente de bugs (instalaba la AppImage
# de mtime más reciente, que podía ser una versión vieja descargada).
install_appimage "$APPIMAGE_PATH" || fail "Instalación del AppImage falló"

# ───────────────────────────────────────────────────────────────────────────
# 8. Tailscale (acceso remoto para soporte)
# -----------------------------------------------------------------------------
# Une el kiosko al tailnet de Flowmastercontrols para que el equipo de soporte
# pueda acceder por SSH (vía Tailscale SSH) y diagnosticar incidencias.
#
# Comportamiento:
#   - OPCIONAL: si no se puede obtener la auth key por ninguna vía, se salta
#     limpio y el kiosko queda sin acceso remoto pero plenamente funcional.
#   - IDEMPOTENTE: si tailscaled ya está corriendo y el nodo ya está unido,
#     no se hace nada. Re-ejecutar el instalador es seguro.
#   - HOSTNAME DETERMINÍSTICO: kiosk-<6-últimos-hex-de-MAC-eth0>. Misma
#     Raspberry → mismo hostname inicial entre reinstalaciones. Tras el
#     bulk-download del Fuelmanager, el propio kiosko se renombra a
#     kiosk-<fm-code> (lo hace bulkDownloadFuelmanager.ts).
#   - --operator=$TARGET_USER permite al usuario que corre el kiosko ejecutar
#     `tailscale set`, `tailscale status`, etc. sin sudo. Esto habilita el
#     rename post-bulk-download sin tener que añadir nada al sudoers.
#
# Cómo se obtiene la auth key (en orden de prioridad, primera fuente que tenga
# valor gana — sirven todas, escoges la más cómoda):
#   1) Variable de entorno TAILSCALE_AUTHKEY:
#        sudo TAILSCALE_AUTHKEY=tskey-auth-xxxxx bash install-raspberry.sh AppImage
#   2) Segundo argumento posicional al script:
#        sudo bash install-raspberry.sh AppImage tskey-auth-xxxxx
#   3) Fichero scripts/tailscale.key junto al script (útil para dev local).
#      MUY IMPORTANTE: este path está en .gitignore.
#   4) Fichero /etc/flowmaster/tailscale.key (persistido tras un install
#      exitoso previo). Permite re-ejecutar el script sin volver a aportar
#      la key.
#   5) Prompt interactivo (si hay TTY disponible). Pega la key o pulsa Enter
#      para omitir Tailscale.
#
# Tras un join exitoso, la key se persiste en /etc/flowmaster/tailscale.key
# (modo 600, root:root) para que futuras re-ejecuciones la encuentren solas.
# ───────────────────────────────────────────────────────────────────────────

# 8.0 — Resolver la auth key recorriendo las fuentes en orden.
resolve_tailscale_authkey() {
  # Fuente 1: env var ya definida
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    log "Auth key Tailscale: variable de entorno"
    return 0
  fi

  # Fuente 2: segundo argumento posicional
  if [[ -n "$TAILSCALE_AUTHKEY_ARG" ]]; then
    TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY_ARG"
    log "Auth key Tailscale: 2º argumento del script"
    return 0
  fi

  # Fuente 3: scripts/tailscale.key (mismo dir del script, dev local)
  local local_key="$SCRIPT_DIR/tailscale.key"
  if [[ -f "$local_key" ]]; then
    local content
    content=$(tr -d '[:space:]' < "$local_key")
    if [[ -n "$content" ]]; then
      TAILSCALE_AUTHKEY="$content"
      log "Auth key Tailscale: cargada desde $local_key"
      return 0
    fi
  fi

  # Fuente 4: clave persistida de un install anterior
  if [[ -f "$TAILSCALE_PERSISTED_KEY_PATH" ]]; then
    local persisted
    persisted=$(tr -d '[:space:]' < "$TAILSCALE_PERSISTED_KEY_PATH")
    if [[ -n "$persisted" ]]; then
      TAILSCALE_AUTHKEY="$persisted"
      log "Auth key Tailscale: cargada de $TAILSCALE_PERSISTED_KEY_PATH (persistida)"
      return 0
    fi
  fi

  # Fuente 5: prompt interactivo (solo si hay TTY accesible)
  if [[ -e /dev/tty ]]; then
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo " Configuración de acceso remoto (Tailscale)"
    echo "════════════════════════════════════════════════════════════════"
    echo " Si quieres que este kiosko sea accesible por SSH remotamente vía"
    echo " Tailscale, pega aquí la auth key (formato: tskey-auth-...)."
    echo " Si pulsas Enter sin escribir nada, se OMITE Tailscale y el kiosko"
    echo " queda instalado sin acceso remoto."
    echo
    local prompted=""
    # Read silently (no echo de la key en pantalla) desde /dev/tty
    if read -r -s -p " Auth key Tailscale (o Enter para omitir): " prompted < /dev/tty; then
      echo  # newline después del prompt silencioso
    fi
    prompted=$(echo "$prompted" | tr -d '[:space:]')
    if [[ -n "$prompted" ]]; then
      TAILSCALE_AUTHKEY="$prompted"
      log "Auth key Tailscale: introducida por prompt"
      return 0
    fi
    log "Sin auth key — Tailscale OMITIDO"
    return 1
  fi

  log "Sin auth key y sin TTY — Tailscale OMITIDO"
  return 1
}

resolve_tailscale_authkey || true   # no fatal: continuamos sin Tailscale

if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
  log "Configurando Tailscale (acceso remoto para soporte)..."

  # 8.1 — Instalar el cliente Tailscale si no está presente
  if ! command -v tailscale >/dev/null 2>&1; then
    log "Instalando agente Tailscale..."
    if ! curl -fsSL https://tailscale.com/install.sh | sh >/dev/null; then
      warn "Falló la instalación de Tailscale — el kiosko sigue, pero sin acceso remoto"
      TAILSCALE_AUTHKEY=""   # desactivar resto del bloque
    else
      ok "Agente Tailscale instalado"
    fi
  else
    ok "Agente Tailscale ya presente"
  fi
fi

if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
  # 8.2 — Calcular hostname determinístico a partir de la MAC de eth0.
  #       Fallback a wlan0 si eth0 no existe (poco común en Pi 5).
  #       Última red de fallback: 6 hex aleatorios — perdemos idempotencia
  #       pero no rompemos la instalación.
  TS_MAC_IFACE="eth0"
  if [[ ! -d "/sys/class/net/$TS_MAC_IFACE" ]]; then
    TS_MAC_IFACE="wlan0"
  fi
  TS_MAC_RAW=$(cat "/sys/class/net/$TS_MAC_IFACE/address" 2>/dev/null || true)
  if [[ -z "$TS_MAC_RAW" ]]; then
    warn "No se pudo leer MAC de $TS_MAC_IFACE — usando sufijo aleatorio"
    TS_MAC_SUFFIX=$(openssl rand -hex 3)
  else
    # Quitar los ':' y coger los 6 últimos hex
    TS_MAC_SUFFIX=$(echo "$TS_MAC_RAW" | tr -d ':' | tail -c 7 | head -c 6)
  fi
  TS_INITIAL_HOSTNAME="kiosk-${TS_MAC_SUFFIX}"
  log "Tailscale hostname inicial: $TS_INITIAL_HOSTNAME (MAC $TS_MAC_IFACE: ${TS_MAC_RAW:-unknown})"

  # 8.3 — Idempotencia: ¿ya estamos unidos al tailnet?
  TS_ALREADY_UP=0
  if systemctl is-active --quiet tailscaled 2>/dev/null; then
    if tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'; then
      TS_ALREADY_UP=1
    fi
  fi

  TS_JOIN_OK=0
  if [[ $TS_ALREADY_UP -eq 1 ]]; then
    TS_CURRENT_HOSTNAME=$(tailscale status --json --self 2>/dev/null \
      | grep -oE '"HostName":[[:space:]]*"[^"]*"' | head -1 \
      | sed -E 's/.*"HostName":[[:space:]]*"([^"]*)".*/\1/')
    TS_CURRENT_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
    ok "Tailscale ya unido al tailnet (hostname: ${TS_CURRENT_HOSTNAME:-?}, IP: ${TS_CURRENT_IP:-?}) — skip join"
    TS_JOIN_OK=1
  else
    log "Uniendo al tailnet como $TS_INITIAL_HOSTNAME ..."
    if tailscale up \
        --authkey="$TAILSCALE_AUTHKEY" \
        --hostname="$TS_INITIAL_HOSTNAME" \
        --advertise-tags=tag:kiosk \
        --ssh \
        --operator="$TARGET_USER" \
        --accept-routes=false; then
      TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
      ok "Tailscale unido al tailnet como $TS_INITIAL_HOSTNAME (IP: ${TS_IP:-?})"
      TS_JOIN_OK=1
    else
      warn "tailscale up falló — revisar la auth key (¿caducada? ¿tag:kiosk no autorizado?)"
    fi
  fi

  # 8.4 — Persistir la key solo si el join fue OK. Así re-ejecuciones del
  #       script (incluido vía DangerZone) no necesitan la key.
  if [[ $TS_JOIN_OK -eq 1 ]]; then
    mkdir -p "$(dirname "$TAILSCALE_PERSISTED_KEY_PATH")"
    chmod 700 "$(dirname "$TAILSCALE_PERSISTED_KEY_PATH")"
    if [[ ! -f "$TAILSCALE_PERSISTED_KEY_PATH" ]] || \
       [[ "$(tr -d '[:space:]' < "$TAILSCALE_PERSISTED_KEY_PATH")" != "$TAILSCALE_AUTHKEY" ]]; then
      printf '%s\n' "$TAILSCALE_AUTHKEY" > "$TAILSCALE_PERSISTED_KEY_PATH"
      chmod 600 "$TAILSCALE_PERSISTED_KEY_PATH"
      chown root:root "$TAILSCALE_PERSISTED_KEY_PATH"
      ok "Auth key persistida en $TAILSCALE_PERSISTED_KEY_PATH (root, 0600)"
    fi
  fi
else
  log "Sin auth key Tailscale — integración OMITIDA (kiosko sin acceso remoto)"
fi

# ───────────────────────────────────────────────────────────────────────────
# 9. wayvnc — ver pantalla del kiosko remotamente (encima de Tailscale)
# -----------------------------------------------------------------------------
# Solo se monta si Tailscale se unió correctamente. Sin Tailscale, el VNC
# quedaría expuesto en LAN sin protección de red — no nos compensa.
#
# Stack:
#   - wayvnc captura la sesión Wayfire del usuario y la sirve como VNC.
#   - Se ejecuta como TARGET_USER (no como root) — necesita el socket Wayland.
#   - Autostart vía XDG autostart del propio usuario (mismo patrón que el
#     launcher del kiosko).
#   - Auth: username (`fuelmanager`) + password (auto-generada o reutilizada).
#     La password se guarda en /etc/flowmaster/wayvnc-password (root, 0600)
#     y se replica al ~/.config/wayvnc/config del TARGET_USER.
#   - Listen en 0.0.0.0:5900. En LAN del cliente queda expuesta pero
#     protegida por password. Para tightening (bind solo a tailscale0)
#     vendrá iptables en v2.
#
# Conexión desde Mac (una vez añadido tcp:5900 al ACL Tailscale):
#   open vnc://kiosk-<hostname>:5900
# ───────────────────────────────────────────────────────────────────────────

if [[ ${TS_JOIN_OK:-0} -eq 1 ]]; then
  log "Configurando wayvnc (acceso remoto a pantalla)..."

  # 9.1 — Instalar wayvnc
  if ! command -v wayvnc >/dev/null 2>&1; then
    log "Instalando wayvnc..."
    if apt-get install -y -qq wayvnc >/dev/null 2>&1; then
      ok "wayvnc instalado"
    else
      warn "Falló apt-get install wayvnc — omitiendo configuración VNC"
      WAYVNC_SKIP=1
    fi
  else
    ok "wayvnc ya instalado"
  fi

  if [[ ${WAYVNC_SKIP:-0} -eq 0 ]]; then
    # 9.2 — Resolver password VNC (reusar la persistida o generar una nueva)
    WAYVNC_PASSWORD_FILE="/etc/flowmaster/wayvnc-password"
    WAYVNC_PASSWORD=""
    if [[ -f "$WAYVNC_PASSWORD_FILE" ]]; then
      WAYVNC_PASSWORD=$(tr -d '[:space:]' < "$WAYVNC_PASSWORD_FILE")
      if [[ -n "$WAYVNC_PASSWORD" ]]; then
        ok "Password VNC reutilizada de $WAYVNC_PASSWORD_FILE"
      fi
    fi
    if [[ -z "$WAYVNC_PASSWORD" ]]; then
      # Password fuerte de 16 chars, solo caracteres URL-safe (sin /, +, =)
      WAYVNC_PASSWORD=$(openssl rand -base64 24 | tr -d '+/=' | cut -c1-16)
      mkdir -p "$(dirname "$WAYVNC_PASSWORD_FILE")"
      chmod 700 "$(dirname "$WAYVNC_PASSWORD_FILE")"
      printf '%s\n' "$WAYVNC_PASSWORD" > "$WAYVNC_PASSWORD_FILE"
      chmod 600 "$WAYVNC_PASSWORD_FILE"
      chown root:root "$WAYVNC_PASSWORD_FILE"
      ok "Password VNC nueva generada y persistida en $WAYVNC_PASSWORD_FILE"
    fi

    # 9.3 — Generar TLS cert/key autofirmado para wayvnc (necesario para
    #       la mayoría de clientes modernos incluido macOS Screen Sharing).
    WAYVNC_CONFIG_DIR="/home/$TARGET_USER/.config/wayvnc"
    WAYVNC_KEY="$WAYVNC_CONFIG_DIR/tls_key.pem"
    WAYVNC_CERT="$WAYVNC_CONFIG_DIR/tls_cert.pem"
    mkdir -p "$WAYVNC_CONFIG_DIR"
    if [[ ! -f "$WAYVNC_KEY" || ! -f "$WAYVNC_CERT" ]]; then
      log "Generando certificado TLS autofirmado para wayvnc..."
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$WAYVNC_KEY" \
        -out "$WAYVNC_CERT" \
        -subj "/CN=kiosk-${TS_MAC_SUFFIX:-unknown}" \
        -days 3650 \
        >/dev/null 2>&1
      ok "TLS cert/key generados en $WAYVNC_CONFIG_DIR"
    else
      ok "TLS cert/key ya presentes en $WAYVNC_CONFIG_DIR"
    fi

    # 9.4 — Escribir config wayvnc
    WAYVNC_CONFIG="$WAYVNC_CONFIG_DIR/config"
    cat > "$WAYVNC_CONFIG" <<EOF
address=0.0.0.0
port=5900
enable_auth=true
username=fuelmanager
password=$WAYVNC_PASSWORD
private_key_file=$WAYVNC_KEY
certificate_file=$WAYVNC_CERT
EOF
    chmod 600 "$WAYVNC_CONFIG"
    chown -R "$TARGET_USER":"$TARGET_USER" "$WAYVNC_CONFIG_DIR"
    ok "Config wayvnc creada: $WAYVNC_CONFIG"

    # 9.5 — Autostart XDG: wayvnc arranca con la sesión Wayfire del usuario.
    #       wayvnc lee config de ~/.config/wayvnc/config automáticamente.
    WAYVNC_AUTOSTART_DIR="/home/$TARGET_USER/.config/autostart"
    WAYVNC_AUTOSTART="$WAYVNC_AUTOSTART_DIR/wayvnc.desktop"
    mkdir -p "$WAYVNC_AUTOSTART_DIR"
    cat > "$WAYVNC_AUTOSTART" <<'EOF'
[Desktop Entry]
Name=WayVNC
Comment=VNC server para acceso remoto a la pantalla del kiosko
Exec=wayvnc
Type=Application
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    chown -R "$TARGET_USER":"$TARGET_USER" "$WAYVNC_AUTOSTART_DIR"
    ok "Autostart wayvnc: $WAYVNC_AUTOSTART"
    log "wayvnc arrancará la próxima vez que '$TARGET_USER' entre en sesión Wayfire."
    log "Para arrancarlo ahora sin esperar al reboot:  pkill wayvnc 2>/dev/null; nohup wayvnc >/dev/null 2>&1 &"
  fi
else
  log "wayvnc OMITIDO — requiere Tailscale activo (sin tailnet no hay protección de red para el VNC)"
fi

# ───────────────────────────────────────────────────────────────────────────
# Verificación final
# ───────────────────────────────────────────────────────────────────────────

INSTALLED_APPIMAGE="/home/$TARGET_USER/.local/share/FuelManager/FuelManager.AppImage"
INSTALLED_EXTRACT_DIR="/home/$TARGET_USER/.local/share/FuelManager/extracted"
INSTALLED_LAUNCHER="/usr/local/bin/fuelmanager"

VERIFY_OK=1

if [[ ! -f "$INSTALLED_APPIMAGE" ]]; then
  warn "VERIFICACIÓN: $INSTALLED_APPIMAGE no existe"
  VERIFY_OK=0
fi

if [[ ! -d "$INSTALLED_EXTRACT_DIR" ]]; then
  warn "VERIFICACIÓN: $INSTALLED_EXTRACT_DIR no existe (extract falló)"
  VERIFY_OK=0
fi

if [[ ! -x "$INSTALLED_LAUNCHER" ]]; then
  warn "VERIFICACIÓN: $INSTALLED_LAUNCHER no existe o no ejecutable"
  VERIFY_OK=0
fi

# Comprobar que el inner binary tiene cap_net_raw (lo que hace que BLE funcione)
INNER_BIN_FOUND=$(find "$INSTALLED_EXTRACT_DIR" -maxdepth 2 -type f -executable \
  \( -name "com.fuelmastercontrol*" -o -name "fuelmanager*" -o -name "FuelManager*" \) \
  -not -name "*.so*" -not -name "AppRun*" -not -name "chrome-sandbox" -not -name "chrome_crashpad_handler" \
  2>/dev/null | head -1)

if [[ -z "$INNER_BIN_FOUND" ]]; then
  warn "VERIFICACIÓN: no se encontró el binario interno tras extraer"
  VERIFY_OK=0
else
  CAPS=$(getcap "$INNER_BIN_FOUND" 2>/dev/null)
  if [[ "$CAPS" != *"cap_net_raw"* ]]; then
    warn "VERIFICACIÓN: binario interno SIN cap_net_raw — BLE no funcionará"
    warn "  $INNER_BIN_FOUND: $CAPS"
    VERIFY_OK=0
  fi
fi

if [[ -d /opt/FuelManager ]]; then
  warn "VERIFICACIÓN: /opt/FuelManager TODAVÍA existe (limpieza falló)"
  VERIFY_OK=0
fi

if [[ ! -f /etc/sudoers.d/fuelmanager ]]; then
  warn "VERIFICACIÓN: /etc/sudoers.d/fuelmanager no existe — re-extracts no funcionarán"
  VERIFY_OK=0
fi

if [[ ! -f /etc/ld.so.conf.d/fuelmanager.conf ]]; then
  warn "VERIFICACIÓN: /etc/ld.so.conf.d/fuelmanager.conf no existe"
  warn "  → el binario crasheará con 'libffmpeg.so: cannot open shared object file'"
  VERIFY_OK=0
elif ! grep -q "$INSTALLED_EXTRACT_DIR" /etc/ld.so.conf.d/fuelmanager.conf; then
  warn "VERIFICACIÓN: ld.so.conf.d/fuelmanager.conf no apunta a $INSTALLED_EXTRACT_DIR"
  VERIFY_OK=0
fi

if [[ $VERIFY_OK -eq 1 ]]; then
  ok "Verificación OK — AppImage + extracción + setcap + sudoers + ld.so.conf.d correctos"
fi

# ───────────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────────

echo
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓  Install complete.${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo

if command -v tailscale >/dev/null 2>&1; then
  TS_FINAL_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
  TS_FINAL_HOSTNAME=$(tailscale status --json --self 2>/dev/null \
    | grep -oE '"HostName":[[:space:]]*"[^"]*"' | head -1 \
    | sed -E 's/.*"HostName":[[:space:]]*"([^"]*)".*/\1/')
  if [[ -n "$TS_FINAL_IP" ]]; then
    echo -e "  ${BLUE}Tailscale${NC}: ${TS_FINAL_HOSTNAME:-?}  (IP: $TS_FINAL_IP)"
    echo "  SSH desde soporte:  ssh fuelmanager@${TS_FINAL_HOSTNAME:-$TS_FINAL_IP}"
    if command -v wayvnc >/dev/null 2>&1 && [[ -f /etc/flowmaster/wayvnc-password ]]; then
      WAYVNC_PASS_OUT=$(tr -d '[:space:]' < /etc/flowmaster/wayvnc-password)
      echo
      echo -e "  ${BLUE}VNC (pantalla)${NC}: vnc://${TS_FINAL_HOSTNAME:-$TS_FINAL_IP}:5900"
      echo "    Usuario:  fuelmanager"
      echo "    Password: $WAYVNC_PASS_OUT"
      echo "    (Para recuperarla luego: sudo cat /etc/flowmaster/wayvnc-password)"
    fi
    echo
  fi
fi

echo "Next steps:"
echo
echo -e "  1. ${YELLOW}REBOOT${NC} the Raspberry Pi to apply kernel changes:"
echo "       sudo reboot"
echo
echo "  2. After reboot, run the check script:"
echo "       bash check-raspberry.sh"
echo
echo "  3. Start the kiosk (any of these works):"
echo "       fuelmanager                                                       # quick command"
echo "       (or click 'FuelManager Kiosk' in the apps menu)"
echo
echo "  4. The kiosk will also auto-start on every login (XDG autostart)."
echo
echo -e "  ${YELLOW}NOTA:${NC} el launcher ejecuta el binario interno EXTRAÍDO del AppImage,"
echo "  no el AppImage directamente. Esto evita el bug FUSE+root en Pi 5 y"
echo "  permite aplicar setcap al binario interno (cap_net_raw, requerido por"
echo "  bleno para BLE peripheral mode). La app corre como tu usuario normal,"
echo "  sin sudo. electron-updater sigue funcionando: cuando reemplace el"
echo "  AppImage, el launcher detectará el cambio (mtime) y re-extraerá +"
echo "  re-aplicará setcap en el siguiente arranque."
echo
