# FuelManager — Installation on Raspberry Pi

This folder contains everything you need to install the FuelManager kiosk on a Raspberry Pi 5 (or 4).

## ⚡ Quick reference — launching the kiosk from SSH

If you're connected via SSH and want to start the kiosk on the Pi's physical screen (not your terminal), Electron needs the display environment vars. The `fuelmanager` launcher itself doesn't set them automatically, so prefix the command:

```bash
DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority fuelmanager
```

Without this, you'll see `Missing X server or $DISPLAY` and a `Segmentation fault` — that's just Electron giving up because it has no display to render on. Not a real bug.

If you launch from a terminal opened directly on the Pi's desktop, just `fuelmanager` works because `DISPLAY` is already set in that session.

---

## What's in this folder

| File | Purpose |
|------|---------|
| `FuelManager-X.X.X-ENV.AppImage` | The kiosk application (single self-contained binary) |
| `install-raspberry.sh` | Installs the AppImage and configures the system in one step |
| `setup-system.sh` | (Legacy) one-time Pi system configuration — superseded by `install-raspberry.sh` |
| `check-raspberry.sh` | Verifies the Pi is ready and the install is correct |
| `RASPBERRY_README.md` | This file |

> **Note:** the `.deb` package is no longer produced. The AppImage is the only application format. Updates are delivered remotely from the cloud via electron-updater — no manual reinstall is needed for new versions.

---

## First-time installation (new Raspberry Pi)

Do these steps only **once per Pi**. After this, future updates are pushed remotely from the cloud — you don't need to come back to the terminal.

### Step 1 — Copy this folder to the Pi

Use `scp`, a USB drive, or any method you prefer:

```bash
# From your laptop
scp -r ./FuelManager-release/ pi@kiosko-ip:/home/pi/
```

Then SSH into the Pi and `cd` into the folder.

### Step 2 — Run the installer

```bash
sudo bash install-raspberry.sh ./FuelManager-X.X.X-ENV.AppImage
```

Replace `X.X.X-ENV` with the actual filename (e.g. `1.9.36-alpha.2-FEATURES`).

The script does everything in one go:

1. Installs system runtime libraries (libusb, libsqlite3, libbluetooth3, libgpiod2, libfuse2, etc).
2. Enables I2C, SPI and UART kernel interfaces.
3. Adds UART overlays to `/boot/firmware/config.txt`.
4. Adds your user to the required groups (`dialout`, `gpio`, `i2c`, `input`, `video`, etc).
5. Installs udev rules for the USB HID card reader.
6. Enables and configures the Bluetooth service for BLE peripheral mode.
7. Fixes `/dev/shm` permissions for the Chromium renderer.
8. Copies the AppImage to `~/.local/share/FuelManager/` (writable location, required by electron-updater).
9. Applies BLE capabilities (`setcap cap_net_raw,cap_net_admin+eip`) to the AppImage.
10. Creates the `/usr/local/bin/fuelmanager` launcher.
11. Creates a `.desktop` menu entry.
12. Enables auto-start on user login (XDG autostart).

Takes about 1-2 minutes the first time.

### Step 3 — Reboot

```bash
sudo reboot
```

This is required for kernel changes (UART overlays, group memberships) to take effect.

### Step 4 — Verify (optional but recommended)

After reboot:

```bash
bash check-raspberry.sh
```

Should show all green checks. If anything is red, the message tells you what to fix.

### Step 5 — Launch the kiosk

The kiosk auto-starts on login. If it didn't, you can launch it manually:

```bash
fuelmanager
```

Or click **FuelManager Kiosk** in the applications menu.

---

## Updating to a new version (remote, from the cloud)

**You do not need to come to the Pi for updates.** Once installed, future versions are pushed remotely:

1. The development team publishes a new release via the cloud SuperAdmin.
2. The kiosk receives the order, downloads the new AppImage in the background, and shows progress on screen.
3. After download a 30-second countdown appears, then the kiosk restarts automatically with the new version.
4. The whole flow is visible to the operator on the kiosk screen — no surprises.

Manual updates (re-running `install-raspberry.sh` with a newer AppImage) are only needed if:

- Cloud delivery is broken (network, S3, etc.).
- A change in `install-raspberry.sh` itself needs to be applied (e.g. new system dependency).

In those cases, repeat the first-time install with the newer AppImage.

---

## Auto-start on boot

`install-raspberry.sh` configures auto-start by creating `~/.config/autostart/fuelmanager.desktop`. The kiosk launches when the user logs into the desktop.

### Disabling auto-start temporarily

```bash
rm ~/.config/autostart/fuelmanager.desktop
```

Re-run the installer (or recreate the file) to re-enable.

### Enabling auto-login (so the kiosk starts without manual login)

```bash
sudo raspi-config
# → System Options → Boot / Auto Login → Desktop Autologin
```

---

## Uninstalling

The AppImage is a user-level install — to remove it:

```bash
rm -rf ~/.local/share/FuelManager/
sudo rm -f /usr/local/bin/fuelmanager
sudo rm -f /usr/share/applications/fuelmanager.desktop
rm -f ~/.config/autostart/fuelmanager.desktop
```

System-level changes (groups, udev, UART overlays, Bluetooth config) are not reverted — they don't interfere with anything else and can stay.

---

## Troubleshooting

**The kiosk opens with a blank window**
Run `sudo chmod 1777 /dev/shm` and relaunch. If this happens repeatedly, re-run `install-raspberry.sh`.

**Bluetooth discovery doesn't work from the mobile app**
The kiosk runs the AppImage with `sudo` because `bleno` (BLE peripheral mode)
requires raw access to the HCI socket, and AppImage's `setcap` does not
propagate to the inner Electron binary. Verify both pieces:

```bash
# 1. The launcher must invoke sudo:
cat /usr/local/bin/fuelmanager   # should contain 'exec sudo ...'

# 2. The sudoers entry must exist with NOPASSWD for the AppImage:
sudo cat /etc/sudoers.d/fuelmanager   # must reference the AppImage path
```

If either is missing, re-run `install-raspberry.sh`.

If both are present and BLE still fails, check the bluetooth daemon:

```bash
systemctl status bluetooth
sudo hciconfig hci0
```

`hci0` should be `UP RUNNING`. If `DOWN`, run `sudo hciconfig hci0 up`.

**The pump controllers don't respond**
The UART overlays may not be applied. Check:

```bash
ls /dev/ttyAMA*
```

Should list at least `/dev/ttyAMA0`. If empty, re-run `install-raspberry.sh` and reboot.

**The card reader is not detected**
Unplug and replug the reader. If the issue persists:

```bash
cat /etc/udev/rules.d/99-fuelmanager.rules
```

Should contain the Syncotek entry. If not, re-run `install-raspberry.sh`.

**The `fuelmanager` command is not found**
The launcher wasn't created. Re-run the installer:

```bash
sudo bash install-raspberry.sh ./FuelManager-X.X.X-ENV.AppImage
```

**A remote update from the cloud never installs**
Check the kiosk has internet access and can reach the cloud (`features.app.flowmastercontrols.com` or `app.flowmastercontrols.com` depending on the environment). Then check the cloud SuperAdmin → Fuelmanagers — the kiosk should show as "Live" with a recent ping.

---

## Support

If something doesn't work, collect the following and contact support:

```bash
bash check-raspberry.sh > check.log 2>&1
```

Send the `check.log` file along with a description of what happened.
