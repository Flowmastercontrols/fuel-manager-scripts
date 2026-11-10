#!/usr/bin/env bash
#
# Instala el agente de parches del SO en una Raspberry.
# Flowmastercontrols/fuel-manager-system#159
#
#   sudo bash scripts/install-os-update-agent.sh [usuario-de-la-app]
#
# Idempotente: se puede volver a lanzar para actualizar el script.
#
# 🔴 Lo que NO instala: ninguna entrada en `sudoers`. La app no eleva
# privilegios en ningun momento — solo deja un fichero, y este agente, que corre
# como root desde un timer de systemd, decide. Ver la cabecera de
# fmc-os-update.sh.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Hay que ejecutarlo con sudo." >&2; exit 1; }

APP_USER="${1:-fuelmanager}"
id "$APP_USER" >/dev/null 2>&1 || { echo "No existe el usuario '$APP_USER'." >&2; exit 1; }

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO=/usr/local/sbin/fmc-os-update

# root:root y 0755. Si el usuario de la app pudiera escribir el script, todo lo
# demas sobra: se limitaria a reescribirlo con lo que quisiera.
install -o root -g root -m 0755 "$AQUI/fmc-os-update.sh" "$DESTINO"
install -d -o root -g root -m 0755 /var/lib/fmc-os-update

cat > /etc/systemd/system/fmc-os-update.service <<UNIT
[Unit]
Description=Aplica los parches del SO que haya ordenado el cloud
Documentation=https://github.com/Flowmastercontrols/cloud/blob/stage/docs/PARCHES-DEL-SISTEMA.md

[Service]
Type=oneshot
# El usuario de la app NO va como argumento de linea de comandos por costumbre:
# va por entorno, para que no haya ninguna cadena que el servicio componga.
Environment=FMC_APP_USER=$APP_USER
ExecStart=$DESTINO
# Una pasada no deberia tardar mas que una instalacion de kernel con su
# initramfs. Si tarda mas, algo va mal y es mejor cortar que dejarlo colgado.
TimeoutStartSec=30min
UNIT

cat > /etc/systemd/system/fmc-os-update.timer <<'UNIT'
[Unit]
Description=Mira cada pocos minutos si hay una orden de parches esperando

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
# Sin esto, toda la flota preguntaria en el mismo segundo tras un corte de luz
# general. No importa aqui —no hay servidor que saturar— pero cuesta una linea.
RandomizedDelaySec=60s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now fmc-os-update.timer

echo "Agente instalado. Usuario de la app: $APP_USER"
echo "  estado:  systemctl status fmc-os-update.timer"
echo "  prueba:  sudo $DESTINO --dry-run"
echo "  log:     /var/lib/fmc-os-update/agent.log"
