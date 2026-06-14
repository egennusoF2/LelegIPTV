#!/usr/bin/env bash
# Apri / segui i log dell'app desktop Leleg IPTV (macOS).
set -euo pipefail

LOG_DIR="${HOME}/Library/Logs/com.lelegiptv.player"
LOG_FILE="${LOG_DIR}/LelegIPTV.log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

echo "Log file: ${LOG_FILE}"
echo ""
echo "Opzione A — da Terminale (vedi errori live):"
echo "  /Applications/LelegIPTV.app/Contents/MacOS/leleg-iptv"
echo ""
echo "Opzione B — ispeziona WebView (Safari):"
echo "  Safari → Sviluppo → [questo Mac] → LelegIPTV"
echo "  (Sviluppo va attivato in Safari → Impostazioni → Avanzate)"
echo ""
echo "Opzione C — segui il file log (Ctrl+C per uscire):"
echo "  tail -f \"${LOG_FILE}\""
echo ""

if [[ "${1:-}" == "--tail" ]]; then
  tail -f "$LOG_FILE"
else
  open -a Console "$LOG_FILE" 2>/dev/null || open "$LOG_DIR" || tail -20 "$LOG_FILE"
fi
