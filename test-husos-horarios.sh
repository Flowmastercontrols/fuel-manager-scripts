#!/usr/bin/env bash
#
# Pasa las suites sensibles al reloj por CUATRO husos horarios.
#
# ## Por qué
#
# Ningún kiosko está en UTC: están en talleres de España, de Estados Unidos y de
# Canadá. Un runner de CI, en cambio, casi siempre sí. Y UTC es justamente el
# peor sitio para probar fechas, porque ahí leer un instante «sin zona» como
# local y como UTC da lo mismo: el fallo no existe. Eso es lo que dejó pasar
# `cloud#69` —un cambio hecho en el cloud se descartaba en el kiosko por parecer
# más antiguo— durante meses.
#
# ## Las cuatro zonas, y por qué esas
#
#   UTC                el CI, y el caso en que el fallo es invisible
#   Europe/Madrid      +1/+2, cambia de hora en fechas distintas a EE. UU.
#   America/New_York   -5/-4, cruza el día hacia atrás
#   America/St_Johns   -3:30/-2:30 — Terranova, el que rompe los cálculos
#                      que asumen husos de hora entera. Es Canadá, hay clientes
#                      potenciales, y no falla en ningún otro sitio del continente.
#
# ## Por qué un script y no un `setupFiles`
#
# **Jest no propaga un cambio de `TZ` hecho desde dentro del test.** Su
# `process.env` es una copia, así que asignarle `TZ` cambia la variable pero no
# el reloj — comprobado: con `TZ=UTC` fuera y `process.env.TZ='Europe/Madrid'`
# dentro, `getTimezoneOffset()` sigue dando 0. La única forma de que el huso
# cuente es fijarlo **antes** de arrancar el proceso, que es lo que hace esto.
#
#   npm run test:husos
#
set -u

ZONAS=(UTC Europe/Madrid America/New_York America/St_Johns)
FALLOS=0

for zona in "${ZONAS[@]}"; do
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  TZ=$zona"
  echo "══════════════════════════════════════════════════════════"

  if ! TZ="$zona" npx jest --config jest.unit.config.js --silent; then
    echo "✗ nivel 0 falla en $zona"
    FALLOS=$((FALLOS + 1))
  fi

  if ! TZ="$zona" npx jest --config jest.db.config.js --silent; then
    echo "✗ nivel 1 falla en $zona"
    FALLOS=$((FALLOS + 1))
  fi
done

echo ""
if [ "$FALLOS" -eq 0 ]; then
  echo "✓ Las suites pasan en los cuatro husos horarios."
else
  echo "✗ $FALLOS suite(s) fallan según el huso horario."
  echo "  Un test que solo pasa en una zona es un fallo de producción esperando"
  echo "  al cliente que esté en otra."
  exit 1
fi
