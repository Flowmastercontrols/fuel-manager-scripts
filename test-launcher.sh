#!/bin/bash
# Prueba el launcher /usr/local/bin/fuelmanager que genera install-raspberry.sh
# (fuel-manager-system#108) sin Raspberry: saca su heredoc del script de
# instalación, lo genera con la misma expansión que la instalación y lo ejecuta
# con un HOME temporal, una AppImage falsa y un `sudo` falso.
#
# El caso que importa es el del 2026-09-29 (kiosk-cxnvtpv0): un apagón a mitad
# de la extracción dejó extracted/ con todos los ficheros a 0 bytes y más
# nuevos que la AppImage, y el launcher viejo no volvía a extraer nunca.
#
#   npm run test:launcher

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$REPO/scripts/install-raspberry.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fallos=0
ok() { echo "  ✓ $1"; }
ko() { echo "  ✗ $1"; fallos=$((fallos + 1)); }

# ── El launcher, generado igual que en la instalación ────────────────────────
inner_bin_relpath="com.fuelmastercontrol.kiosko"
heredoc="$(sed -n '/cat > "\$launcher" <<EOF/,/^EOF$/p' "$INSTALL" | sed '1d;$d')"
if [[ -z "$heredoc" ]]; then
  echo "No encuentro el heredoc del launcher en $INSTALL"
  exit 1
fi
LAUNCHER="$TMP/fuelmanager"
eval "cat > \"\$LAUNCHER\" <<EOF
$heredoc
EOF"
chmod +x "$LAUNCHER"
bash -n "$LAUNCHER" || { echo "El launcher generado no es bash válido"; exit 1; }

# ── Dobles ───────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"

# AppImage falsa: --appimage-extract crea squashfs-root con un binario que
# escribe RUN-OK y cuenta las extracciones en $HOME/extracciones.
nueva_appimage() {
  local destino="$1"
  mkdir -p "$(dirname "$destino")"
  cat > "$destino" <<'FAKE'
#!/bin/bash
if [[ "${1:-}" == "--appimage-extract" ]]; then
  mkdir -p squashfs-root/resources
  printf '#!/bin/bash\necho RUN-OK\n' > squashfs-root/com.fuelmastercontrol.kiosko
  chmod +x squashfs-root/com.fuelmastercontrol.kiosko
  echo contenido > squashfs-root/resources/app.asar
  echo x >> "$HOME/extracciones"
  exit 0
fi
exit 1
FAKE
  chmod +x "$destino"
}

# Cada escenario en un HOME limpio.
escenario() {
  export HOME="$TMP/home-$1"
  rm -rf "$HOME"
  APP_DIR="$HOME/.local/share/FuelManager"
  EXTRACTED="$APP_DIR/extracted"
  BIN="$EXTRACTED/com.fuelmastercontrol.kiosko"
  MARK="$EXTRACTED/.extraction-complete"
  LOG="$HOME/.config/FuelManager/logs/kiosk-stdout.log"
  nueva_appimage "$APP_DIR/FuelManager.AppImage"
  touch -t 202601010000 "$APP_DIR/FuelManager.AppImage"
}

arrancar() { PATH="$TMP/bin:$PATH" "$LAUNCHER" >/dev/null 2>&1; }
extracciones() { [[ -f "$HOME/extracciones" ]] && wc -l < "$HOME/extracciones" | tr -d ' ' || echo 0; }
arranco() { grep -q RUN-OK "$LOG" 2>/dev/null; }

# ── Escenarios ───────────────────────────────────────────────────────────────
echo "1. Sin extracción previa"
escenario 1
arrancar
arranco && ok "arranca" || ko "no arranca"
[[ -f "$MARK" ]] && ok "deja la marca" || ko "no deja la marca"
[[ -s "$BIN" ]] && ok "binario con contenido" || ko "binario vacío"

echo "2. Apagón a mitad de extracción (29-09): todo a 0 bytes, sin marca, más nuevo que la AppImage"
escenario 2
mkdir -p "$EXTRACTED/resources"
: > "$BIN"; chmod +x "$BIN"; : > "$EXTRACTED/resources/app.asar"
arrancar
[[ "$(extracciones)" == 1 ]] && ok "re-extrae" || ko "no re-extrae ($(extracciones))"
arranco && ok "arranca" || ko "no arranca"
[[ -s "$EXTRACTED/resources/app.asar" ]] && ok "no quedan ficheros vacíos" || ko "quedan ficheros vacíos"

echo "3. Extracción al día y con marca"
escenario 3
arrancar; : > "$HOME/extracciones"
arrancar
[[ "$(extracciones)" == 0 ]] && ok "no re-extrae" || ko "re-extrae sin necesidad"
arranco && ok "arranca" || ko "no arranca"

echo "4. Llega una AppImage nueva (más reciente que la marca)"
escenario 4
arrancar; : > "$HOME/extracciones"
touch -t 202601010000 "$MARK"
touch "$APP_DIR/FuelManager.AppImage"
arrancar
[[ "$(extracciones)" == 1 ]] && ok "re-extrae" || ko "no re-extrae"

echo "5. Marca presente pero binario vacío"
escenario 5
arrancar; : > "$HOME/extracciones"
: > "$BIN"
arrancar
[[ "$(extracciones)" == 1 ]] && ok "re-extrae" || ko "no re-extrae"
arranco && ok "arranca" || ko "no arranca"

echo "6. Restos de un squashfs-root cortado a medias"
escenario 6
mkdir -p "$APP_DIR/squashfs-root/basura"
arrancar
[[ ! -e "$APP_DIR/squashfs-root" ]] && ok "limpia los restos" || ko "quedan restos"
[[ ! -e "$EXTRACTED/basura" ]] && ok "los restos no acaban en extracted/" || ko "los restos acaban en extracted/"
arranco && ok "arranca" || ko "no arranca"

echo "7. Kiosko con el launcher viejo: extracción buena pero sin marca"
escenario 7
arrancar; rm -f "$MARK"; : > "$HOME/extracciones"
arrancar
[[ "$(extracciones)" == 1 ]] && ok "re-extrae una vez" || ko "no re-extrae"
arrancar
[[ "$(extracciones)" == 1 ]] && ok "y después ya no" || ko "sigue re-extrayendo"

echo
if [[ $fallos -eq 0 ]]; then
  echo "Launcher: todo OK"
else
  echo "Launcher: $fallos fallo(s)"
  exit 1
fi
