#!/usr/bin/env bash
# Point OpenClaw gateway at the Heretic BeeLlama stack on port 8080.
#
# Usage:
#   bash /home/hermes/llama/scripts/openclaw-point-heretic.sh

set -euo pipefail

PORT="${1:-8080}"
OPENCLAW_JSON="/home/hermes/.openclaw/openclaw.json"
BACKUP_JSON="${OPENCLAW_JSON}.bak-heretic"

CTX=131072
NAME="Qwen3.6-27B-NEO-CODE-HERE-2T-OT-IQ4_NL.gguf"
DESC="Heretic IQ4_NL + DFlash"

if [[ "$PORT" != "8080" && "$PORT" != "8082" ]]; then
  echo "Error: Port must be either 8080 or 8082." >&2
  exit 1
fi

if [[ ! -f "${OPENCLAW_JSON}" ]]; then
  echo "Error: OpenClaw config not found at ${OPENCLAW_JSON}." >&2
  exit 1
fi

if [[ ! -f "${BACKUP_JSON}" ]]; then
  echo "Creating one-time backup: ${OPENCLAW_JSON} -> ${BACKUP_JSON}"
  cp "${OPENCLAW_JSON}" "${BACKUP_JSON}"
fi

echo "=== Pointing OpenClaw to Port ${PORT} (${DESC}) ==="

jq --arg url "http://127.0.0.1:${PORT}" \
   --argjson ctx "${CTX}" \
   --arg name "${NAME}" \
   '.models.providers["custom-127-0-0-1"].baseUrl = $url | .models.providers["custom-127-0-0-1"].models[0].contextWindow = $ctx | .models.providers["custom-127-0-0-1"].models[0].name = $name' \
   "${OPENCLAW_JSON}" > "${OPENCLAW_JSON}.tmp"

mv "${OPENCLAW_JSON}.tmp" "${OPENCLAW_JSON}"
echo "✓ Configuration updated successfully."

echo "=== Restarting OpenClaw Gateway ==="
openclaw gateway stop || true
sleep 1
openclaw gateway start

echo "✓ OpenClaw gateway restarted. Currently pointing to http://127.0.0.1:${PORT}."
