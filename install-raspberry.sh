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

# ───────────────────────────────────────────────────────────────────────────
# Preflight
# ───────────────────────────────────────────────────────────────────────────

require_root

log "FuelManager Kiosk — production install (user: $TARGET_USER)"

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

  # 6. Sudoers: only allow the user to run setcap on this specific path.
  #    Needed because the launcher re-extracts after every electron-updater
  #    update and re-applies setcap (which requires root). The scope is
  #    intentionally tiny — no NOPASSWD on the AppImage itself.
  local sudoers_file=/etc/sudoers.d/fuelmanager
  cat > "$sudoers_file" <<EOF
# Permite a $TARGET_USER aplicar setcap al binario interno extraído del
# FuelManager. Necesario para que el launcher pueda re-aplicar setcap
# tras cada update remoto (electron-updater reemplaza el AppImage; el
# launcher detecta el cambio, re-extrae, y necesita re-setcap).
#
# Scope estrictamente limitado a este comando + path concreto.
# Generado por install-raspberry.sh — NO EDITAR a mano.
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/setcap cap_net_raw\\,cap_net_admin+eip $inner_bin
EOF
  chmod 440 "$sudoers_file"

  if visudo -cf "$sudoers_file" >/dev/null 2>&1; then
    ok "Sudoers entry (solo setcap): $sudoers_file"
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
