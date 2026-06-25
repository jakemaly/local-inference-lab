#!/usr/bin/env bash
# Start the Gemma 4 QAT MTP llama-server service.
# Installs the systemd unit, starts it, waits for readiness.
set -euo pipefail

ROOT="/home/hermes/llama"
UNIT_NAME="llama-server-gemma4-qat-mtp"
UNIT_SRC="${ROOT}/systemd/${UNIT_NAME}.service"
UNIT_DST="/etc/systemd/system/${UNIT_NAME}.service"

echo "=== Gemma 4 QAT MTP Start ==="

# 1. Check model exists
BASE_MODEL="${ROOT}/models/gemma-4-31b-qat-mtp/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"
DRAFT_MODEL="${ROOT}/models/gemma-4-31b-qat-mtp/mtp-gemma-4-31B-it.gguf"
if [[ ! -f "${BASE_MODEL}" ]] || [[ ! -f "${DRAFT_MODEL}" ]]; then
  echo "Model not found. Downloading..."
  bash "${ROOT}/scripts/download-gemma4-qat-mtp.sh"
fi

# 2. Check llama-server is built
if [[ ! -x "${ROOT}/llama.cpp/build/bin/llama-server" ]]; then
  echo "✗ llama-server not found. Build llama.cpp first." >&2
  exit 1
fi

# 3. Stop any existing service on port 8080
sudo systemctl stop llama-server.service 2>/dev/null || true

# 4. Install the unit
sudo cp "${UNIT_SRC}" "${UNIT_DST}"
sudo systemctl daemon-reload

# 5. Start the service
sudo systemctl start "${UNIT_NAME}.service"

# 6. Wait for readiness
LLAMA_URL="http://127.0.0.1:8080"
WAIT_SECS=300
echo "⏳ Waiting for Gemma 4 QAT server at ${LLAMA_URL} (up to ${WAIT_SECS}s) ..."
i=0
ready=0
while (( i < WAIT_SECS )); do
  if curl -sf -m 3 "${LLAMA_URL}/v1/models" >/dev/null 2>&1; then
    echo "✓ Gemma 4 QAT server ready! (${i}s)"
    ready=1
    break
  fi
  sleep 2
  i=$((i + 2))
done

if [[ "$ready" -ne 1 ]]; then
  echo "✗ Server failed to start within ${WAIT_SECS}s. Check: journalctl -u ${UNIT_NAME} -n 50" >&2
  exit 1
fi

# 7. Quick sanity
echo "=== Sanity check ==="
curl -sf -m 30 "${LLAMA_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Capital of France? One word."}],"max_tokens":10,"temperature":0.0}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || true

echo ""
echo "✓ Gemma 4 QAT MTP started on port 8080."
echo "  Check logs: journalctl -u ${UNIT_NAME} -f"
