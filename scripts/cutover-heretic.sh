#!/usr/bin/env bash
# Cutover active llama-server.service on port 8080 to Heretic IQ4_NL + BeeLlama.
# Refuses to run if rollback script is missing.
#
# Usage:
#   bash /home/hermes/llama/scripts/cutover-heretic.sh

set -euo pipefail

ROOT="/home/hermes/llama"
cd "${ROOT}"

ROLLBACK_SCRIPT="${ROOT}/scripts/rollback-to-phase2.sh"
PHASE2_ARCHIVE="${ROOT}/systemd/llama-server-phase2-mtp.service"
CURRENT_UNIT="${ROOT}/systemd/llama-server.service"
HERETIC_UNIT="${ROOT}/systemd/llama-server-heretic.service"

echo "=== Heretic Cutover Process ==="

if [[ ! -f "${ROLLBACK_SCRIPT}" ]]; then
  echo "✗ Error: Safety rollback script missing at ${ROLLBACK_SCRIPT}." >&2
  echo "  You MUST have rollback-to-phase2.sh before cutting over." >&2
  exit 1
fi
echo "✓ Safety check: Rollback script is present."

if [[ ! -f "${HERETIC_UNIT}" ]]; then
  echo "✗ Error: Heretic unit missing at ${HERETIC_UNIT}." >&2
  exit 1
fi

if [[ ! -f "/home/hermes/llama/models/heretic/Qwen3.6-27B-NEO-CODE-HERE-2T-OT-IQ4_NL.gguf" ]]; then
  echo "✗ Error: Heretic model not downloaded. Run deploy-heretic.sh first." >&2
  exit 1
fi

if [[ ! -f "${PHASE2_ARCHIVE}" ]]; then
  echo "Archiving current Phase 2 MTP service unit..."
  cp "${CURRENT_UNIT}" "${PHASE2_ARCHIVE}"
  git add "${PHASE2_ARCHIVE}" 2>/dev/null || true
  echo "✓ Phase 2 unit archived at ${PHASE2_ARCHIVE}."
else
  echo "✓ Phase 2 unit already archived at ${PHASE2_ARCHIVE}."
fi

echo "Stopping active services..."
sudo systemctl stop llama-server.service || true
sudo systemctl stop llama-server-heretic.service || true
sudo systemctl stop llama-server-bee.service || true
echo "✓ Services stopped."

echo "Generating new Heretic llama-server.service for port 8080..."
sed -e 's/--port 8082/--port 8080/g' \
    -e 's/Heretic validation profile (port 8082)/Heretic production profile (port 8080)/g' \
    "${HERETIC_UNIT}" > "${CURRENT_UNIT}"
echo "✓ llama-server.service updated for port 8080."

echo "Installing updated systemd unit..."
bash scripts/install-systemd.sh

echo "Starting llama-server.service with Heretic IQ4_NL..."
sudo systemctl start llama-server.service

LLAMA_URL="http://127.0.0.1:8080"
WAIT_SECS=180
echo "⏳ Waiting for llama-server to initialize at ${LLAMA_URL}..."
i=0
ready=0
while (( i < WAIT_SECS )); do
  if curl -sf -m 3 "${LLAMA_URL}/v1/models" >/dev/null 2>&1; then
    echo "✓ llama-server is ready!"
    ready=1
    break
  fi
  sleep 2
  i=$((i + 2))
done

if [[ "$ready" -ne 1 ]]; then
  echo "✗ Error: llama-server failed to start within ${WAIT_SECS} seconds." >&2
  echo "  Check journal: journalctl -u llama-server -n 50" >&2
  exit 1
fi

echo "Switching OpenClaw gateway to Heretic on port 8080..."
bash scripts/openclaw-point-heretic.sh 8080

echo "=== Running Heretic Verification on port 8080 ==="
export LLAMA_URL="http://127.0.0.1:8080"
export LLAMA_PORT="8080"
if bash tests/verify-heretic.sh; then
  echo "✓ Heretic Verification PASSED on port 8080."
else
  echo "✗ Error: Heretic Verification FAILED on port 8080." >&2
  echo "  Roll back immediately: bash scripts/rollback-to-phase2.sh" >&2
  exit 1
fi

echo "=== Heretic Cutover SUCCESSFUL! ==="
echo "Active stack: BeeLlama + Heretic IQ4_NL on port 8080 (128K YaRN, temp 1.0)."
echo "Rollback: bash scripts/rollback-to-phase2.sh"
