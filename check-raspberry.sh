#!/usr/bin/env bash
# =============================================================================
# FuelManager Kiosk — Raspberry Pi System Check
# -----------------------------------------------------------------------------
# Verifies that everything required by the kiosk is properly configured.
# Each check is annotated with what it enables in the kiosk.
#
# Usage:
#   bash scripts/check-raspberry.sh
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m'

pass_count=0
fail_count=0
warn_count=0

# Arrays to build the final summary
declare -a summary_items=()

pass()  { echo -e "${GREEN}✓${NC}  $1  ${GRAY}$2${NC}"; ((pass_count++)); summary_items+=("OK|$1|$2"); }
fail()  { echo -e "${RED}✗${NC}  $1  ${GRAY}$2${NC}"; ((fail_count++));  summary_items+=("FAIL|$1|$2"); }
warn()  { echo -e "${YELLOW}⚠${NC}  $1  ${GRAY}$2${NC}"; ((warn_count++)); summary_items+=("WARN|$1|$2"); }
info()  { echo -e "${BLUE}ℹ${NC}  $1  ${GRAY}$2${NC}"; }
header() { echo; echo -e "${BLUE}─── $1 ───${NC}"; }

# ───────────────────────────────────────────────────────────────────────────
# Load tested-system reference (expected model / OS / kernel)
# ───────────────────────────────────────────────────────────────────────────

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TESTED_CONF="$SCRIPT_DIR/tested-system.conf"
if [[ -f "$TESTED_CONF" ]]; then
  # shellcheck disable=SC1090
  . "$TESTED_CONF"
else
  EXPECTED_MODEL=""
  EXPECTED_OS_CODENAME=""
  EXPECTED_OS_VERSION_ID=""
  EXPECTED_RPI_IMAGE_DATE=""
  EXPECTED_KERNEL_MAJOR_MINOR=""
  EXPECTED_ARCH="aarch64"
fi

# ───────────────────────────────────────────────────────────────────────────
header "System"
# ───────────────────────────────────────────────────────────────────────────

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  pass "OS: $PRETTY_NAME" "— base operating system"
  if [[ -n "$EXPECTED_OS_CODENAME" ]]; then
    if [[ "${VERSION_CODENAME:-}" == "$EXPECTED_OS_CODENAME" && "${VERSION_ID:-}" == "$EXPECTED_OS_VERSION_ID" ]]; then
      pass "OS matches tested version" "— Debian ${EXPECTED_OS_VERSION_ID} (${EXPECTED_OS_CODENAME})"
    else
      warn "OS differs from tested version" "— tested on Debian ${EXPECTED_OS_VERSION_ID} (${EXPECTED_OS_CODENAME}), got ${VERSION_ID:-?} (${VERSION_CODENAME:-?}). Kiosk may work but is unverified."
    fi
  fi
else
  warn "Cannot detect OS" "— script may not work as expected"
fi

if [[ -f /etc/rpi-issue ]]; then
  RPI_ISSUE_LINE=$(head -n1 /etc/rpi-issue)
  RPI_IMAGE_DATE=$(echo "$RPI_ISSUE_LINE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1)
  if [[ -n "$EXPECTED_RPI_IMAGE_DATE" && -n "$RPI_IMAGE_DATE" ]]; then
    if [[ "$RPI_IMAGE_DATE" == "$EXPECTED_RPI_IMAGE_DATE" ]]; then
      pass "RPi OS image: $RPI_IMAGE_DATE" "— matches tested image"
    else
      warn "RPi OS image: $RPI_IMAGE_DATE" "— tested image is $EXPECTED_RPI_IMAGE_DATE. Flash that release for a verified setup."
    fi
  else
    info "RPi OS image: ${RPI_IMAGE_DATE:-unknown}" ""
  fi
fi

if [[ -f /proc/device-tree/model ]]; then
  MODEL=$(tr -d '\0' < /proc/device-tree/model)
  pass "Hardware: $MODEL" "— target platform"
  if [[ -n "$EXPECTED_MODEL" ]]; then
    if echo "$MODEL" | grep -qi "$EXPECTED_MODEL"; then
      pass "Model matches tested hardware" "— $EXPECTED_MODEL"
    else
      warn "Model differs from tested hardware" "— tested on '$EXPECTED_MODEL', got '$MODEL'. Pin-outs and power requirements may differ."
    fi
  fi
fi

KERNEL=$(uname -r)
if [[ -n "$EXPECTED_KERNEL_MAJOR_MINOR" ]]; then
  if [[ "$KERNEL" == ${EXPECTED_KERNEL_MAJOR_MINOR}.* ]]; then
    pass "Kernel: $KERNEL" "— matches tested ${EXPECTED_KERNEL_MAJOR_MINOR}.x branch"
  else
    warn "Kernel: $KERNEL" "— tested on ${EXPECTED_KERNEL_MAJOR_MINOR}.x. Out-of-tree modules (GPIO, I2C) may behave differently."
  fi
fi

ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
  pass "Architecture: $ARCH" "— ARM64 needed for Pi 5 AppImage"
else
  warn "Architecture: $ARCH" "— expected aarch64/arm64 for Pi 5"
fi

# ───────────────────────────────────────────────────────────────────────────
header "Runtime libraries (needed by the AppImage at runtime)"
# ───────────────────────────────────────────────────────────────────────────

check_pkg() {
  if dpkg -l "$1" 2>/dev/null | grep -q ^ii; then
    pass "$1" "$2"
  else
    fail "$1 missing" "$2"
  fi
}

check_pkg "libusb-1.0-0"     "— USB device access (card reader, RFID over USB-serial)"
check_pkg "libsqlite3-0"     "— local SQLite database (vessels, drivers, transactions)"
check_pkg "libbluetooth3"    "— Bluetooth stack (BLE advertising for mobile discovery)"
check_pkg "libgpiod2"        "— GPIO access (physical buttons / switches on the kiosk)"
check_pkg "bluez"            "— BlueZ Bluetooth daemon (required by BLE)"
check_pkg "bluetooth"        "— Bluetooth init scripts / metapackage (installed alongside bluez)"
check_pkg "libfuse2"         "— FUSE (required to execute AppImage format)"
check_pkg "i2c-tools"        "— i2cdetect / i2cget (diagnosing HAT vessel controllers)"

# ───────────────────────────────────────────────────────────────────────────
header "Kernel interfaces (hardware buses)"
# ───────────────────────────────────────────────────────────────────────────

# I2C
if [[ -c /dev/i2c-1 ]]; then
  pass "I2C bus 1 (/dev/i2c-1)" "— FuelManHat vessel controllers (addresses 0x2F+)"
  if command -v i2cdetect >/dev/null 2>&1; then
    DEVS=$(i2cdetect -y 1 2>/dev/null | awk 'NR>1 {for(i=2;i<=NF;i++) if($i!="--" && $i!~/^[0-9]+:$/) print $i}' | tr '\n' ' ')
    if [[ -n "${DEVS// /}" ]]; then
      info "    I2C devices detected: $DEVS" ""
    else
      info "    No I2C devices detected (normal if HAT not connected yet)" ""
    fi
  fi
else
  fail "I2C bus 1 not available" "— FuelManHat will not work"
fi

# UART
UARTS=$(ls /dev/ttyAMA* 2>/dev/null || true)
if [[ -n "$UARTS" ]]; then
  pass "UART ports: $(echo $UARTS | tr '\n' ' ')" "— MTR_PCB pump controller serial comm"
else
  fail "No /dev/ttyAMA* ports" "— MTR_PCB communication will not work"
fi

# GPIO
if ls /dev/gpiochip* >/dev/null 2>&1; then
  pass "GPIO chips: $(ls /dev/gpiochip* 2>/dev/null | tr '\n' ' ')" "— physical buttons on pins 17,5,27,22,6,26,25,16"
else
  fail "GPIO not available" "— physical buttons will not work"
fi

# SPI (optional)
if ls /dev/spidev* >/dev/null 2>&1; then
  pass "SPI: $(ls /dev/spidev* | tr '\n' ' ')" "— currently unused (future sensors / displays)"
else
  info "SPI not enabled" "— optional, not required by current kiosk code"
fi

# USB serial (optional)
USB_SERIALS=$(ls /dev/ttyUSB* 2>/dev/null || true)
if [[ -n "$USB_SERIALS" ]]; then
  info "USB serial: $(echo $USB_SERIALS | tr '\n' ' ')" "— RFID reader or USB-to-UART adapter"
fi

# ───────────────────────────────────────────────────────────────────────────
header "Bluetooth"
# ───────────────────────────────────────────────────────────────────────────

if systemctl is-active --quiet bluetooth; then
  pass "bluetooth.service running" "— required for BLE advertising"
else
  fail "bluetooth.service not running" "— mobile app will not discover kiosk via BLE"
fi

# Adapter status — prefer hciconfig, fall back to bluetoothctl (which is always
# present with bluez on Bookworm, while hciconfig moved to bluez-deprecated-tools).
if command -v hciconfig >/dev/null 2>&1; then
  if hciconfig 2>/dev/null | grep -q "UP RUNNING"; then
    ADDR=$(hciconfig 2>/dev/null | grep -oE 'BD Address: [0-9A-F:]+' | head -1 | cut -d' ' -f3)
    pass "BLE adapter UP (MAC $ADDR)" "— ready to advertise 'fuelmanager' service"
  else
    fail "BLE adapter DOWN" "— sudo hciconfig hci0 up"
  fi
elif command -v bluetoothctl >/dev/null 2>&1; then
  BCTL_SHOW=$(bluetoothctl show 2>/dev/null || true)
  if [[ -n "$BCTL_SHOW" ]]; then
    if echo "$BCTL_SHOW" | grep -qE 'Powered:\s*yes'; then
      ADDR=$(echo "$BCTL_SHOW" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -1)
      pass "BLE adapter powered (MAC $ADDR)" "— ready to advertise 'fuelmanager' service"
    else
      fail "BLE adapter not powered" "— sudo bluetoothctl power on"
    fi
  else
    fail "No BLE controller detected by bluetoothctl" "— hardware missing or driver not loaded"
  fi
else
  warn "Neither hciconfig nor bluetoothctl available" "— cannot verify adapter state"
fi

# rfkill — a soft block silently prevents BLE advertising even when the
# service is up. Common after a fresh image or when the kiosk case has a
# physical bluetooth-disable switch.
if command -v rfkill >/dev/null 2>&1; then
  RFKILL_BT=$(rfkill list bluetooth 2>/dev/null || true)
  if [[ -n "$RFKILL_BT" ]]; then
    if echo "$RFKILL_BT" | grep -qE 'Soft blocked:\s*yes'; then
      fail "Bluetooth soft-blocked by rfkill" "— sudo rfkill unblock bluetooth"
    elif echo "$RFKILL_BT" | grep -qE 'Hard blocked:\s*yes'; then
      fail "Bluetooth hard-blocked by rfkill" "— physical switch / firmware disabled BT"
    else
      pass "rfkill: bluetooth unblocked" "— no soft/hard block in the way"
    fi
  fi
fi

# ───────────────────────────────────────────────────────────────────────────
header "User permissions"
# ───────────────────────────────────────────────────────────────────────────

TARGET_USER="${SUDO_USER:-$USER}"
USER_GROUPS=$(id -nG "$TARGET_USER" 2>/dev/null)

check_group() {
  if getent group "$1" >/dev/null 2>&1; then
    if echo " $USER_GROUPS " | grep -q " $1 "; then
      pass "User '$TARGET_USER' in group '$1'" "$2"
    else
      warn "User '$TARGET_USER' NOT in '$1'" "$2 (logout/login to refresh)"
    fi
  fi
}

check_group "dialout"  "— access /dev/ttyAMA* and /dev/ttyUSB* (serial ports)"
check_group "gpio"     "— access GPIO lines (buttons)"
check_group "input"    "— access HID devices (card reader)"
check_group "video"    "— X11 / display server access (Electron window)"
check_group "audio"    "— audio output (if kiosk plays sounds)"
check_group "i2c"      "— access /dev/i2c-* (FuelManHat)"
check_group "spi"      "— access /dev/spidev* (future use)"
check_group "plugdev"  "— access hotpluggable USB devices"

# ───────────────────────────────────────────────────────────────────────────
header "udev rules"
# ───────────────────────────────────────────────────────────────────────────

if [[ -f /etc/udev/rules.d/99-fuelmanager.rules ]]; then
  pass "99-fuelmanager.rules present" "— USB HID card reader accessible without sudo"
else
  warn "99-fuelmanager.rules missing" "— SK-288-K001 card reader may need sudo"
fi

# ───────────────────────────────────────────────────────────────────────────
header "USB devices (detected now)"
# ───────────────────────────────────────────────────────────────────────────

if command -v lsusb >/dev/null 2>&1; then
  if lsusb | grep -qi "23d8:0285\|syncotek"; then
    pass "Syncotek SK-288-K001" "— USB HID card/fob reader"
  else
    info "Syncotek card reader not detected" "— optional hardware"
  fi

  if lsusb | grep -qi "067b:2303\|Prolific"; then
    info "Prolific PL2303" "— USB-to-serial (may be used for RFID reader)"
  fi
fi

# ───────────────────────────────────────────────────────────────────────────
header "Shared memory"
# ───────────────────────────────────────────────────────────────────────────

if [[ -d /dev/shm ]]; then
  PERMS=$(stat -c '%a' /dev/shm 2>/dev/null)
  if [[ "$PERMS" == "1777" ]]; then
    pass "/dev/shm permissions: $PERMS" "— Chromium can allocate shared memory"
  else
    fail "/dev/shm permissions: $PERMS (need 1777)" "— Electron will show a blank page. Run: sudo chmod 1777 /dev/shm"
  fi
else
  fail "/dev/shm not present" "— Electron renderer requires shared memory"
fi

# ───────────────────────────────────────────────────────────────────────────
header "Boot configuration"
# ───────────────────────────────────────────────────────────────────────────

BOOT_CONFIG=/boot/firmware/config.txt
[[ -f /boot/config.txt && ! -f $BOOT_CONFIG ]] && BOOT_CONFIG=/boot/config.txt

if grep -q "FuelManager UART overlays" "$BOOT_CONFIG" 2>/dev/null; then
  pass "UART overlays in $BOOT_CONFIG" "— added by install-raspberry.sh"
else
  warn "UART overlays marker missing" "— UART may still work if enabled manually via raspi-config"
fi

# ───────────────────────────────────────────────────────────────────────────
header "Installed kiosk (production)"
# ───────────────────────────────────────────────────────────────────────────

# install-raspberry.sh extracts the AppImage to /opt/FuelManager/ and applies
# setcap to the *inner* Electron binary, not to the .AppImage file itself.
# The launcher at /usr/local/bin/fuelmanager is what actually runs the kiosk.

INSTALL_DIR=/opt/FuelManager
LAUNCHER=/usr/local/bin/fuelmanager

if [[ -d "$INSTALL_DIR" ]]; then
  pass "$INSTALL_DIR/ exists" "— AppImage extracted by install-raspberry.sh"

  # Locate the inner Electron binary the same way install-raspberry.sh does
  MAIN_BIN=$(find "$INSTALL_DIR" -maxdepth 2 -type f -executable \
    \( -name "com.fuelmastercontrol*" -o -name "fuelmanager*" -o -name "FuelManager*" -o -name "electron" \) \
    -not -name "*.so*" -not -name "AppRun*" -not -name "chrome-sandbox" -not -name "chrome_crashpad_handler" \
    2>/dev/null | head -1)

  if [[ -n "$MAIN_BIN" ]]; then
    pass "Main binary: $MAIN_BIN" "— actual process launched by the kiosk"
    if command -v getcap >/dev/null 2>&1; then
      if getcap "$MAIN_BIN" 2>/dev/null | grep -q cap_net_raw; then
        pass "  ↳ has cap_net_raw" "— BLE advertising works without sudo"
      else
        fail "  ↳ missing cap_net_raw" "— sudo setcap cap_net_raw+eip '$MAIN_BIN' (BLE will fail with 'unauthorized')"
      fi
    else
      warn "getcap not installed" "— cannot verify cap_net_raw on main binary"
    fi
  else
    warn "Main binary not found inside $INSTALL_DIR" "— extraction may be incomplete; re-run install-raspberry.sh"
  fi
else
  info "$INSTALL_DIR/ not present" "— OK if not yet installed in production"
fi

if [[ -f "$LAUNCHER" ]]; then
  if [[ -x "$LAUNCHER" ]]; then
    pass "Launcher $LAUNCHER" "— entry point used to start the kiosk"
  else
    warn "Launcher $LAUNCHER not executable" "— chmod +x $LAUNCHER"
  fi
elif [[ -d "$INSTALL_DIR" ]]; then
  warn "Launcher $LAUNCHER missing" "— install-raspberry.sh creates this; re-run installer"
fi

# ───────────────────────────────────────────────────────────────────────────
header "AppImage source files (if present)"
# ───────────────────────────────────────────────────────────────────────────

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
APPIMAGES=$(
  find \
    "$SCRIPT_DIR" \
    "$SCRIPT_DIR/.." \
    "$SCRIPT_DIR/../release/build" \
    "/home/${SUDO_USER:-$USER}/Desktop" \
    "/home/${SUDO_USER:-$USER}/Documents" \
    -maxdepth 4 \
    \( -name "*FuelManager*.AppImage" -o -name "*fuel-manag*.AppImage" \) \
    2>/dev/null | sort -u
)

check_ble_caps() {
  local binary="$1"
  local label="$2"
  if command -v getcap >/dev/null 2>&1; then
    local caps
    caps=$(getcap "$binary" 2>/dev/null || true)
    if echo "$caps" | grep -q cap_net_raw && echo "$caps" | grep -q cap_net_admin; then
      pass "  ↳ $label BLE caps OK" "— cap_net_raw,cap_net_admin+eip"
    elif echo "$caps" | grep -q cap_net_raw; then
      warn "  ↳ $label has cap_net_raw only" "— run: sudo setcap cap_net_raw,cap_net_admin+eip '$binary'"
    else
      fail "  ↳ $label missing BLE caps" "— run: sudo setcap cap_net_raw,cap_net_admin+eip '$binary'"
    fi
  fi
}

# Check deb-installed binary at /opt/FuelManager
if [[ -d /opt/FuelManager ]]; then
  for candidate in fuelmanager FuelManager com.fuelmastercontrol.kiosko electron; do
    BIN="/opt/FuelManager/$candidate"
    if [[ -x "$BIN" ]]; then
      pass "Installed binary: $BIN" ""
      check_ble_caps "$BIN" "$candidate"
      break
    fi
  done
fi

if [[ -n "$APPIMAGES" ]]; then
  while IFS= read -r APP; do
    [[ -z "$APP" ]] && continue
    info "AppImage: $APP" "— source archive (extract to $INSTALL_DIR via install-raspberry.sh)"
    [[ -x "$APP" ]] \
      && info "  ↳ executable" "" \
      || warn "  ↳ not executable" "— chmod +x '$APP'"
  done <<< "$APPIMAGES"
else
  info "No AppImage source file found" "— OK if already installed at $INSTALL_DIR or running from source"
fi

# ───────────────────────────────────────────────────────────────────────────
header "Development mode (running with 'npm start')"
# ───────────────────────────────────────────────────────────────────────────

# When running from source, bleno needs cap_net_raw on the node binary itself
# (see ble.ts comment about 'unauthorized' state).
if command -v node >/dev/null 2>&1; then
  NODE_BIN=$(readlink -f "$(command -v node)")
  if command -v getcap >/dev/null 2>&1; then
    if getcap "$NODE_BIN" 2>/dev/null | grep -q cap_net_raw; then
      pass "node has cap_net_raw ($NODE_BIN)" "— BLE works in dev mode without sudo"
    else
      info "node lacks cap_net_raw ($NODE_BIN)" "— only required for 'npm start'; in production setcap is on the inner Electron binary"
    fi
  fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Categorized summary
# ───────────────────────────────────────────────────────────────────────────

echo
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Summary — what was checked and why                               ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"

print_category() {
  local title="$1"
  echo
  echo -e "${BLUE}$title${NC}"
}

cat <<'EOF'

  Legend:  ✓ = working   ⚠ = warning (may still work)   ✗ = problem

  ── What the kiosk needs and why ────────────────────────────────────────

  HARDWARE INTERFACES
    • UART     Communication with the MTR_PCB (pump controllers) over
               serial. Without this, vessels cannot be controlled.
    • I2C      Communication with FuelManHat (alternative vessel
               controller board). Optional if using MTR_PCB only.
    • GPIO     Physical buttons connected to the kiosk case (pins
               17,5,27,22,6,26,25,16).
    • USB HID  Card reader SK-288-K001 (driver/vehicle authentication).
    • BLE      Advertising so the mobile FuelManager app can discover
               this kiosk over Bluetooth.

  RUNTIME LIBRARIES (linked by the AppImage at startup)
    • libusb-1.0-0       USB device access for card reader / RFID
    • libsqlite3-0       Local SQLite DB (drivers, vessels, transactions)
    • libbluetooth3      BLE peripheral advertising
    • libgpiod2          GPIO line access (buttons)
    • bluez              Bluetooth service daemon
    • bluetooth          Bluetooth init scripts metapackage
    • libfuse2           AppImage filesystem (needed to launch AppImage)
    • i2c-tools          Diagnostic tools (i2cdetect)

  USER PERMISSIONS (the user running the kiosk must be in these groups)
    • dialout            access to /dev/ttyAMA* and /dev/ttyUSB* (serial)
    • gpio               GPIO line access
    • input              HID card reader access
    • video              Electron window / X11 display
    • i2c, spi           I2C / SPI bus access
    • plugdev            hotplug USB devices

  SYSTEM CONFIGURATION
    • UART overlays in /boot/firmware/config.txt (enables ttyAMA0/4/10)
    • udev rule /etc/udev/rules.d/99-fuelmanager.rules for card reader
    • cap_net_raw+eip on the inner Electron binary inside /opt/FuelManager
      (the AppImage is extracted there, and setcap is applied to the inner
      binary — NOT to the .AppImage file). Without it, BLE fails with
      'unauthorized' state and the mobile app cannot discover the kiosk.
    • Bluetooth not blocked by rfkill (soft/hard blocks silently disable BLE)
    • /dev/shm with mode 1777 (Chromium needs writable shared memory,
      otherwise the Electron window appears blank)

EOF

echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo
echo -e "  ${GREEN}Passed:${NC}   $pass_count"
echo -e "  ${YELLOW}Warnings:${NC} $warn_count"
echo -e "  ${RED}Failed:${NC}   $fail_count"
echo

if [[ $fail_count -eq 0 ]]; then
  echo -e "${GREEN}✓ System ready to run the FuelManager kiosk${NC}"
  exit 0
else
  echo -e "${RED}✗ $fail_count critical check(s) failed. Fix the issues above.${NC}"
  exit 1
fi
