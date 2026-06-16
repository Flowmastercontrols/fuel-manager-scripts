#!/usr/bin/env bash
# =============================================================================
# FuelManager Kiosk — Raspberry Pi system setup
# -----------------------------------------------------------------------------
# Configures the Raspberry Pi for the FuelManager kiosk hardware.
# Run this ONCE on a fresh Pi, then reboot.
#
# After this, install the kiosk app via:
#     sudo bash install-raspberry.sh path/to/FuelManager-X.X.X-ENV.AppImage
#
# What this script does:
#   1. Enables I2C, SPI and UART via raspi-config
#   2. Adds UART overlays to /boot/firmware/config.txt
#   3. Adds the user to required hardware groups (dialout, gpio, i2c, etc.)
#   4. Installs udev rules for the USB HID card reader
#
# What it does NOT do (handled by install-raspberry.sh):
#   • Installing the FuelManager app (extracts the AppImage to /opt/FuelManager)
#   • Installing runtime libraries (apt deps: libusb, libsqlite3, libgpiod2, ...)
#   • setcap cap_net_raw on the inner Electron binary (required for BLE)
#   • Bluetooth service enable
#   • /dev/shm permissions
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}==>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
fail()  { echo -e "${RED}✗${NC}  $*"; exit 1; }

[[ $EUID -ne 0 ]] && fail "Run with sudo: sudo bash $0"

TARGET_USER="${SUDO_USER:-$USER}"

log "FuelManager — system setup for user '$TARGET_USER'"

# ───────────────────────────────────────────────────────────────────────────
# 0a-bis. Check defensivo del reloj + garantía NTP
# -----------------------------------------------------------------------------
# Mismo bloque que en install-raspberry.sh, compartido via _lib-clock.sh.
# setup-system no usa apt directamente, pero suele ejecutarse en una SD
# recién flasheada — el momento exacto donde más probable es que el reloj
# esté mal. Lo arreglamos AHORA para que cuando luego se corra
# install-raspberry no haya sorpresas.
# ───────────────────────────────────────────────────────────────────────────

FUEL_SCRIPTS_REPO_RAW="${FUEL_SCRIPTS_REPO_RAW:-https://raw.githubusercontent.com/Flowmastercontrols/fuel-manager-scripts/main}"
SCRIPT_DIR_FOR_LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR_FOR_LIB=""
if [[ -n "$SCRIPT_DIR_FOR_LIB" && -f "$SCRIPT_DIR_FOR_LIB/_lib-clock.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR_FOR_LIB/_lib-clock.sh"
else
  _TMP_LIB="$(mktemp)"
  if curl -fsSL "$FUEL_SCRIPTS_REPO_RAW/_lib-clock.sh" -o "$_TMP_LIB" && [[ -s "$_TMP_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_TMP_LIB"
    rm -f "$_TMP_LIB"
  else
    rm -f "$_TMP_LIB"
    fail "No se pudo cargar _lib-clock.sh (ni local junto al script ni desde $FUEL_SCRIPTS_REPO_RAW/_lib-clock.sh). ¿Sin internet?"
  fi
fi

check_clock_or_fail
ensure_ntp_synced

# ───────────────────────────────────────────────────────────────────────────
# 1. Enable kernel interfaces
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
# 2. UART overlays in /boot/firmware/config.txt
# ───────────────────────────────────────────────────────────────────────────

BOOT_CONFIG=/boot/firmware/config.txt
[[ -f /boot/config.txt && ! -f $BOOT_CONFIG ]] && BOOT_CONFIG=/boot/config.txt

log "Configuring UART overlays in $BOOT_CONFIG..."

if grep -q "FuelManager UART overlays" "$BOOT_CONFIG" 2>/dev/null; then
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
# 3. User groups
# ───────────────────────────────────────────────────────────────────────────

log "Adding user '$TARGET_USER' to hardware groups..."

for group in dialout gpio input video audio i2c spi plugdev; do
  if getent group "$group" >/dev/null 2>&1; then
    usermod -aG "$group" "$TARGET_USER"
  fi
done

ok "User groups configured (logout/login required)"

# ───────────────────────────────────────────────────────────────────────────
# 4. udev rules
# ───────────────────────────────────────────────────────────────────────────

log "Installing udev rules for USB HID card reader..."

cat > /etc/udev/rules.d/99-fuelmanager.rules <<'EOF'
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
# Done
# ───────────────────────────────────────────────────────────────────────────

echo
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓  System setup complete.${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo
echo "Next steps:"
echo
echo -e "  1. ${YELLOW}REBOOT${NC} to apply UART overlays and kernel changes:"
echo "       sudo reboot"
echo
echo "  2. After reboot, install the FuelManager kiosk app:"
echo "       sudo bash install-raspberry.sh path/to/FuelManager-X.X.X-ENV.AppImage"
echo
echo "  3. Verify everything is working:"
echo "       bash check-raspberry.sh"
echo
echo "  4. Launch the kiosk:"
echo "       fuelmanager"
echo
