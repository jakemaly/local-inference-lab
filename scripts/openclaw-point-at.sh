#!/usr/bin/env bash
# Flip OpenClaw provider baseUrl between port 8080 (Phase 2 MTP) and port 8082 (Phase 3 BeeLlama).
# Also updates the model name and context window to match the configuration.
#
# Usage:
#   bash /home/hermes/llama/scripts/openclaw-point-at.sh [8080|8082]

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [8080|8082]" >&2
  exit 1
fi

PORT="$1"
OPENCLAW_JSON="/home/hermes/.openclaw/openclaw.json"
BACKUP_JSON="${OPENCLAW_JSON}.bak-phase3"

if [[ "$PORT" != "8080" && "$PORT" != "8082" ]]; then
  echo "Error: Port must be either 8080 or 8082." >&2
  exit 1
fi

if [[ ! -f "${OPENCLAW_JSON}" ]]; then
  echo "Error: OpenClaw config not found at ${OPENCLAW_JSON}." >&2
  exit 1
fi

# 1. Determine model metadata
if [[ "$PORT" == "8082" ]]; then
  CTX=122800
  NAME="Qwen3.6-27B-Q5_K_S.gguf"
  DESC="BeeLlama Precision Combo"
else
  CTX=131072
  NAME="Qwen3.6-27B-Q4_K_M.gguf"
  DESC="Phase 2 MTP Mainline"
fi

# 2. Back up config if backup does not exist yet
if [[ ! -f "${BACKUP_JSON}" ]]; then
  echo "Creating one-time backup: ${OPENCLAW_JSON} -> ${BACKUP_JSON}"
  cp "${OPENCLAW_JSON}" "${BACKUP_JSON}"
fi

echo "=== Pointing OpenClaw to Port ${PORT} (${DESC}) ==="

# 3. Apply edits using jq
jq --arg url "http://127.0.0.1:${PORT}" \
   --argjson ctx "${CTX}" \
   --arg name "${NAME}" \
   '.models.providers["custom-127-0-0-1"].baseUrl = $url | .models.providers["custom-127-0-0-1"].models[0].contextWindow = $ctx | .models.providers["custom-127-0-0-1"].models[0].name = $name' \
   "${OPENCLAW_JSON}" > "${OPENCLAW_JSON}.tmp"

mv "${OPENCLAW_JSON}.tmp" "${OPENCLAW_JSON}"
echo "✓ Configuration updated successfully."

# 4. Restart OpenClaw gateway
echo "=== Restarting OpenClaw Gateway ==="
openclaw gateway stop || true
sleep 1
openclaw gateway start

echo "✓ OpenClaw gateway restarted. Currently pointing to http://127.0.0.1:${PORT}."
