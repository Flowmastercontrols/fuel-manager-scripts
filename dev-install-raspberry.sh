#!/usr/bin/env bash
# =============================================================================
# FuelManager Kiosk — Raspberry Pi 5 DEVELOPMENT Install Script
# -----------------------------------------------------------------------------
# Extends install-raspberry.sh (production) with the tools needed to run the
# kiosk from source on a Raspberry Pi (i.e. 'npm start' or 'npm run package').
#
# Use this if you are a DEVELOPER working on the kiosk code on the Pi.
# End users (running the AppImage) should use install-raspberry.sh instead.
#
# What it adds on top of the production install:
#   • build-essential, python3, pkg-config (to compile native modules)
#   • -dev headers for native module compilation (libusb, libudev, libsqlite3,
#     libbluetooth, libgpiod)
#   • Node.js 20 LTS (for npm install + electron-rebuild)
#   • setcap on the Node.js binary (so dev mode can advertise BLE)
#   • Optional: runs 'npm install' in the project root
#
# Usage:
#   sudo bash dev-install-raspberry.sh
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

[[ $EUID -ne 0 ]] && fail "Run with sudo. Try: sudo bash $0"

TARGET_USER="${SUDO_USER:-$USER}"
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# ───────────────────────────────────────────────────────────────────────────
# 1. First run the production install
# ───────────────────────────────────────────────────────────────────────────

log "Running production install first..."
bash "$SCRIPT_DIR/install-raspberry.sh"

# ───────────────────────────────────────────────────────────────────────────
# 2. Development tools + headers
# ───────────────────────────────────────────────────────────────────────────

log "Installing development tools and headers..."

apt-get install -y -qq \
  build-essential \
  python3 \
  python3-pip \
  pkg-config \
  git \
  curl \
  ruby-full \
  ruby-dev \
  libusb-1.0-0-dev \
  libudev-dev \
  libsqlite3-dev \
  libbluetooth-dev \
  libgpiod-dev \
  > /dev/null

# Install fpm (needed by electron-builder to create .deb on ARM64)
if ! command -v fpm >/dev/null 2>&1; then
  log "Installing fpm (to build .deb packages on ARM64)..."
  gem install fpm --no-document || warn "fpm install failed — .deb builds may not work"
fi

ok "Dev tools installed"

# ───────────────────────────────────────────────────────────────────────────
# 3. Node.js 20 LTS
# ───────────────────────────────────────────────────────────────────────────

NODE_REQUIRED=20

if command -v node >/dev/null 2>&1; then
  CURRENT=$(node --version | sed 's/v//' | cut -d. -f1)
  if [[ $CURRENT -ge $NODE_REQUIRED ]]; then
    ok "Node.js $(node --version) already installed"
  else
    warn "Node $(node --version) detected — upgrading to v$NODE_REQUIRED LTS"
    INSTALL_NODE=1
  fi
else
  INSTALL_NODE=1
fi

if [[ "${INSTALL_NODE:-0}" == 1 ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_REQUIRED}.x" | bash -
  apt-get install -y -qq nodejs > /dev/null
  ok "Node.js $(node --version) installed"
fi

# ───────────────────────────────────────────────────────────────────────────
# 4. BLE capability on Node binary (for 'npm start')
# ───────────────────────────────────────────────────────────────────────────

NODE_BIN=$(readlink -f "$(which node)")
if [[ -x "$NODE_BIN" ]]; then
  setcap cap_net_raw+eip "$NODE_BIN"
  ok "cap_net_raw+eip granted to $NODE_BIN"
fi

# Also setcap on the Electron binary if the project has it.
# In dev mode (npm start), Electron is the actual process that needs BLE access.
ELECTRON_BIN=$(find . -path './node_modules/electron/dist/electron' -type f 2>/dev/null | head -1)
if [[ -n "$ELECTRON_BIN" && -x "$ELECTRON_BIN" ]]; then
  setcap cap_net_raw+eip "$ELECTRON_BIN"
  ok "cap_net_raw+eip granted to project Electron binary"
  warn "Re-apply setcap on Electron after every 'npm install' or Electron upgrade"
fi

# ───────────────────────────────────────────────────────────────────────────
# 5. Optional: npm install
# ───────────────────────────────────────────────────────────────────────────

if [[ -f package.json ]] && grep -q '"name": "com.fuelmastercontrol.kiosko"' package.json 2>/dev/null; then
  read -r -p "Run 'npm install' in current directory? [y/N] " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    sudo -u "$TARGET_USER" npm install
    ok "npm install complete"
  fi
fi

echo
echo -e "${GREEN}✓ Development install complete.${NC}"
echo
echo "Next steps:"
echo "  sudo reboot"
echo "  cd /path/to/kiosko2"
echo "  npm install        # if not done already"
echo "  DISPLAY=:0 npm start"
echo
