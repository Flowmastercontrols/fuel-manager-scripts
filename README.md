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

#### Sinopsis

```text
sudo [TAILSCALE_AUTHKEY=tskey-auth-...] \
  bash install-raspberry.sh <APPIMAGE_PATH> [TAILSCALE_AUTHKEY]
```

**Parámetros:**

- **`<APPIMAGE_PATH>`** *(argumento posicional `$1`, **obligatorio**)* — Ruta al `.AppImage` del FuelManager a instalar. Ejemplo: `release/build/FuelManager-1.9.36-alpha.2-FEATURES.AppImage`.
- **`[TAILSCALE_AUTHKEY]`** *(argumento posicional `$2`, opcional)* — Auth key Tailscale (formato `tskey-auth-...`). Si no se pasa aquí, se busca en otras fuentes (ver más abajo).
- **`TAILSCALE_AUTHKEY`** *(variable de entorno, opcional)* — Misma key Tailscale. Prevalece sobre `$2` si ambas están presentes.

#### Ejemplo mínimo (sin acceso remoto)

```bash
sudo bash install-raspberry.sh ./FuelManager-X.X.X-ENV.AppImage
```

#### Ejemplo con acceso remoto

```bash
# Variante A — segundo argumento posicional
sudo bash install-raspberry.sh ./FuelManager-X.X.X-ENV.AppImage tskey-auth-xxxxx

# Variante B — variable de entorno (útil para scripting / CI)
sudo TAILSCALE_AUTHKEY=tskey-auth-xxxxx bash install-raspberry.sh ./FuelManager-X.X.X-ENV.AppImage
```

#### Fuentes desde las que se resuelve la auth key Tailscale (orden de prioridad)

El script intenta cada fuente en este orden y se queda con la **primera** que tenga valor:

1. Variable de entorno `TAILSCALE_AUTHKEY`.
2. Segundo argumento posicional del script (`$2`).
3. Fichero `scripts/tailscale.key` junto al instalador (útil en desarrollo local; está en `.gitignore`).
4. Fichero `/etc/flowmaster/tailscale.key` — **persistido automáticamente** tras un install exitoso. Re-ejecuciones del script (incluido desde DangerZone) la encuentran sin que tengas que aportarla otra vez.
5. **Prompt interactivo silencioso** — solo si el script corre en TTY y no se encontró la key en las fuentes anteriores. Pegas la key (no se muestra en pantalla) o pulsas Enter para omitir Tailscale.

Si ninguna fuente proporciona la key **y** no hay TTY (ej. invocación desde DangerZone), el kiosko se instala sin acceso remoto — funcional, pero sin SSH para soporte.

La auth key se genera en `https://login.tailscale.com/admin/settings/keys` (Reusable ✅, Ephemeral ❌, tag `tag:kiosk` ✅, Pre-approved ✅, expiración 90 días).

#### Qué hace el script

1. **Crea el usuario `fuelmanager`** si no existe — le pide el password interactivamente (necesario para `sudo` desde sesiones Tailscale SSH del equipo de soporte). Si ya existe, no lo toca.
2. Instala las librerías de runtime (libusb, libsqlite3, libbluetooth3, libgpiod2, libfuse2, etc).
3. Habilita las interfaces de kernel I2C, SPI y UART.
4. Añade los overlays UART a `/boot/firmware/config.txt`.
5. Añade el usuario actual a los grupos hardware (`dialout`, `gpio`, `i2c`, `input`, `video`, etc).
6. Instala las reglas udev del lector USB HID.
7. Habilita y configura el servicio Bluetooth para modo BLE peripheral.
8. Arregla permisos de `/dev/shm` (necesario para el renderer Chromium).
9. Copia el AppImage a `~/.local/share/FuelManager/` (writable, requerido por electron-updater).
10. Aplica `setcap cap_net_raw,cap_net_admin+eip` al binario interno extraído.
11. Crea el launcher `/usr/local/bin/fuelmanager`.
12. Crea un `.desktop` para el menú de aplicaciones.
13. Habilita el auto-start en login del usuario actual (XDG autostart).
14. **(Solo si hay auth key Tailscale)** Instala el agente Tailscale y une el kiosko al tailnet con hostname `kiosk-<6-últimos-hex-MAC-eth0>` y tag `tag:kiosk`. Es **idempotente**: si ya estaba unido, se salta. Persiste la auth key en `/etc/flowmaster/tailscale.key` (0600 root:root) para futuras re-ejecuciones. Tras el primer bulk-download del Fuelmanager, el kiosko se autorenombra a `kiosk-<fm-code>`.
15. **(Solo si Tailscale se unió correctamente)** Asegura que el `wayvnc` nativo del Pi OS está habilitado (`raspi-config nonint do_vnc 0`). No instalamos nada paralelo — Pi OS ya gestiona wayvnc con sus systemd services (`wayvnc.service` + `wayvnc-control.service`), auth PAM y TLS cert auto-generado. Limpia ficheros residuales de versiones anteriores del script que sí montaban un wayvnc propio.

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

## Conectarse remotamente al kiosko (Tailscale + VNC)

Una vez el kiosko está unido al tailnet y wayvnc configurado, el equipo de soporte puede conectarse desde cualquier sitio sin abrir puertos en el router del cliente.

### Pre-requisitos para el cliente (Mac / Windows / Linux)

1. **Tailscale** instalado en el cliente y logueado con una cuenta que esté en `group:support` del ACL de la empresa.
   - Mac: [tailscale.com/download/mac](https://tailscale.com/download/mac) o Mac App Store.
   - Windows: [tailscale.com/download/windows](https://tailscale.com/download/windows).
   - Linux: `curl -fsSL https://tailscale.com/install.sh | sh`.
2. Verificar que el kiosko aparece en la lista de devices Tailscale (admin panel o `tailscale status`).

### Conexión SSH

Funciona en todos los sistemas igual:

```bash
ssh <usuario>@kiosk-<hostname>
# Ejemplo: ssh fuelmanager@kiosk-63cdb5
# o:       ssh lucas@kiosk-63cdb5
```

Tailscale SSH autentica por identidad de tailnet — **no pide password local** para entrar. La password local solo se pide al ejecutar `sudo` dentro de la sesión.

### Conexión VNC (ver/manejar pantalla del kiosko)

El kiosko expone el wayvnc nativo del Pi OS en el puerto 5900 con auth **PAM + TLS**. Pi OS lo configura solo — nosotros no gestionamos ni passwords VNC separadas ni certificados a mano.

**Cómo funciona la autenticación:**

- Pi OS usa el módulo PAM `pam_allow_desktopuser` que SOLO permite conectar al **usuario que tiene activa la sesión gráfica** (el del autologin de Wayfire).
- Eso significa que las credenciales VNC son las **del sistema Linux** de ese usuario.

**Credenciales:**

- **Hostname:** `kiosk-<hostname>` (visible en panel Tailscale, ej. `kiosk-63cdb5`).
- **Puerto:** `5900`.
- **Username:** el usuario con autologin del kiosko:
  - **Producción** (kioskos flasheados con el imager FuelManager): `fuelmanager`.
  - **Desarrollo** (Pi flasheado con un usuario distinto, ej. `lucas`, `pi`, `admin`): ese mismo usuario.
  - Si no sabes cuál: en el kiosko, `loginctl list-sessions` te muestra qué UID tiene `seat0` y qué usuario lo posee.
- **Password:** la **password Linux** de ese usuario. La misma que usas para `sudo`. NO hay password VNC separada.

> **Importante**: si intentas conectar como un usuario que no es el del autologin, recibirás un fallo con mensaje `pam_allow_desktopuser ... another user is already using the desktop`. Es comportamiento esperado.

#### Desde Mac

**No uses el cliente nativo de Screen Sharing** — da problemas con el TLS autofirmado de Pi OS y mensajes de error poco útiles. Usa **TigerVNC**:

```bash
# Instalación (una sola vez):
arch -arm64 brew install --cask tigervnc-viewer

# Conexión:
open -a TigerVNC
# En el diálogo "VNC server:" escribe → kiosk-<hostname>:5900
```

Acepta el certificado autofirmado la primera vez. Mete username (`fuelmanager` o el que tenga autologin) + password Linux.

> **Truco**: NO uses `open vnc://kiosk-...:5900` desde Mac. macOS intercepta el esquema `vnc://` y lo abre con Screen Sharing.app en vez de TigerVNC. Para que vaya a TigerVNC, abre la app sin URL (`open -a TigerVNC`) y mete el server manualmente.

#### Desde Windows

Recomendado: **TigerVNC Viewer**.

1. Descarga el `.exe` desde [https://tigervnc.org](https://tigervnc.org) (`vncviewer64-X.X.X.exe` — no requiere instalación, es un binario portable).
2. Lánzalo.
3. **VNC server:** `kiosk-<hostname>:5900` → Connect.
4. Acepta el certificado autofirmado (Continue).
5. Introduce username + password Linux del usuario con autologin.

Alternativa: **RealVNC Viewer** ([realvnc.com/connect/download/viewer](https://www.realvnc.com/connect/download/viewer/)) — instalador Windows estándar.

#### Desde Linux

Cualquier cliente VNC moderno: TigerVNC, Remmina, Vinagre.

```bash
vncviewer kiosk-<hostname>:5900
```

### Problemas comunes

- **"Invalid username or password" / `pam_allow_desktopuser ... another user is already using the desktop`**: estás intentando entrar como un usuario que NO es el del autologin gráfico. Cambia al usuario que tiene la sesión Wayfire (`loginctl list-sessions` te lo dice).
- **"Connection refused"** / **"Operation timed out"**: el kiosko aún no ha entrado en sesión Wayfire (sin sesión gráfica activa, no hay nada que capturar). Espera al autologin o haz reboot. Comprueba en el Pi: `sudo systemctl status wayvnc.service`.
- **"Certificate not trusted"**: el cert es autofirmado, es normal. Acepta y continúa. Si tu cliente se niega rotundamente, usa TigerVNC que es tolerante.
- **El kiosko aparece en Tailscale pero el VNC no responde**: verifica que `wayvnc.service` está activo: `ssh <user>@kiosk-... "sudo systemctl status wayvnc"`. Si no lo está: `sudo systemctl enable --now wayvnc.service`.

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

## Running scripts from inside the kiosk (Admin → DangerZone → System Scripts)

The kiosk has a built-in button to run these scripts without SSH. Useful when an operator is on-site and needs to verify the install:

|Button|Script|Risk|When to use|
|------|------|----|-----------|
|**RUN DIAGNOSTICS**|`check-raspberry.sh`|None (read-only)|Anytime, even mid-fueling. Verifies BLE, UART, I2C, USB, libraries, AppImage state.|
|**RE-VERIFY CONFIG**|`setup-system.sh`|Low (sudo, idempotent)|After OS update, or to re-apply UART/I2C/SPI overlays + udev rules.|
|**REINSTALL FROM SCRATCH**|`install-raspberry.sh`|High (kills kiosk)|Only when nobody is fueling. Reinstalls from current AppImage. **DB is preserved** (lives in `~/.config/`, untouched).|

The scripts are **downloaded on the fly** from the public repo `Flowmastercontrols/fuel-manager-scripts` (always the latest version on `main`). No need to update the kiosk to get script updates.

`setup-system.sh` and `install-raspberry.sh` are run via `sudo` without password thanks to the entry in `/etc/sudoers.d/fuelmanager` configured by `install-raspberry.sh`. Scope is strictly limited to `/tmp/fuel-setup-system.sh` and `/tmp/fuel-install-raspberry.sh *`.

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
