#!/usr/bin/env bash
#
# fix-electron-signature.sh — repara la firma de código del Electron de desarrollo
# en macOS (Apple Silicon).
#
# PROBLEMA: en un momento dado Apple REVOCÓ la notarización del build de Electron
# que trae este proyecto (le pasó a muchos devs cuando Apple revocó un certificado
# que Electron usaba). Cuando eso ocurre, al arrancar el kiosko en el Mac aparece
# el diálogo "«Electron» dañará tu ordenador. Deberías trasladarlo a la papelera"
# y el proceso muere con SIGKILL (AMFI). NO es malware ni es un fallo del código:
# es la notarización revocada + firma Developer-ID que macOS ya no acepta.
#
# ARREGLO: re-firmar el .app en AD-HOC (firma local, sin Developer-ID) → macOS deja
# de comprobar la notarización revocada y lo ejecuta. Hay que firmar TAMBIÉN las 4
# "Helper apps" anidadas y el framework; `codesign --deep` a secas se las salta y el
# SIGKILL persiste (por eso este script las firma explícitamente).
#
# Es un no-op en Linux (la Raspberry Pi), así que es seguro dejarlo en `postinstall`.
# Cada `npm install` re-descarga el Electron revocado, así que este script lo vuelve
# a arreglar automáticamente.
#
# Uso manual:  npm run fix:electron-signature   (o: bash scripts/fix-electron-signature.sh)

set -euo pipefail

# Solo macOS. En la Pi/Linux/CI no hay nada que firmar.
if [ "$(uname)" != "Darwin" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$ROOT/node_modules/electron/dist/Electron.app"

if [ ! -d "$APP" ]; then
  # Electron aún no instalado (o ruta distinta): nada que hacer.
  exit 0
fi

# Si la firma ya es válida, no repetimos (idempotente + rápido en arranques normales).
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "[fix-electron] Firma de Electron ya válida — nada que hacer."
  exit 0
fi

echo "[fix-electron] Firma inválida (notarización revocada). Re-firmando ad-hoc…"

# 1) Limpiar atributos extendidos (quarantine, provenance, etc.).
xattr -cr "$APP" || true

# 2) Firmar el framework principal.
codesign --force --sign - \
  "$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework" >/dev/null 2>&1 || true

# 3) Firmar las Helper apps anidadas (Renderer/GPU/Plugin/…). --deep a secas las omite.
for helper in "$APP/Contents/Frameworks/"*.app; do
  [ -d "$helper" ] || continue
  codesign --force --deep --sign - "$helper" >/dev/null 2>&1 || true
done

# 4) Firmar el bundle externo (con --deep cubre Mantle/ReactiveObjC/Squirrel).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# 5) Verificar.
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "[fix-electron] ✓ Electron re-firmado y verificado."
else
  echo "[fix-electron] ⚠ La verificación sigue fallando. Prueba a reinstalar Electron o a subir de versión (ver CLAUDE.md → Troubleshooting)." >&2
  # No abortamos el install por esto.
fi
