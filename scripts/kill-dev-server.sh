#!/usr/bin/env bash
# Stop Astro/Vite dev server on port 4321 (and stray node children).
set -euo pipefail

PORT="${1:-4321}"

echo "Cerco processi sulla porta ${PORT}..."
PIDS="$(lsof -ti tcp:"${PORT}" 2>/dev/null || true)"

if [ -z "${PIDS}" ]; then
  echo "Nessun processo in ascolto sulla porta ${PORT}."
else
  echo "Termino PID: ${PIDS}"
  kill -9 ${PIDS} 2>/dev/null || true
  sleep 1
fi

if lsof -ti tcp:"${PORT}" >/dev/null 2>&1; then
  echo "ATTENZIONE: la porta ${PORT} è ancora occupata."
  lsof -i tcp:"${PORT}"
  exit 1
fi

echo "Porta ${PORT} libera. Puoi avviare: pnpm dev:clean"
