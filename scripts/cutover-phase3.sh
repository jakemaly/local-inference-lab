#!/usr/bin/env bash
# Cutover active llama-server.service on port 8080 to Phase 3 BeeLlama.
# Refuses to run if rollback script is missing.
#
# Usage:
#   bash /home/hermes/llama/scripts/cutover-phase3.sh

set -euo pipefail

ROOT="/home/hermes/llama"
cd "${ROOT}"

ROLLBACK_SCRIPT="${ROOT}/scripts/rollback-to-phase2.sh"
PHASE2_ARCHIVE="${ROOT}/systemd/llama-server-phase2-mtp.service"
CURRENT_UNIT="${ROOT}/systemd/llama-server.service"
BEE_UNIT="${ROOT}/systemd/llama-server-bee.service"

echo "=== Phase 3 Cutover Process ==="

# 1. Check safety constraint: rollback script must exist
if [[ ! -f "${ROLLBACK_SCRIPT}" ]]; then
  echo "✗ Error: Safety rollback script missing at ${ROLLBACK_SCRIPT}." >&2
  echo "  You MUST create the rollback script before cutting over." >&2
  exit 1
fi
echo "✓ Safety check: Rollback script is present."

# 2. Archive current Phase 2 service unit if not already archived
if [[ ! -f "${PHASE2_ARCHIVE}" ]]; then
  echo "Archiving current Phase 2 MTP service unit..."
  cp "${CURRENT_UNIT}" "${PHASE2_ARCHIVE}"
  git add "${PHASE2_ARCHIVE}"
  echo "✓ Phase 2 unit archived at ${PHASE2_ARCHIVE}."
else
  echo "✓ Phase 2 unit already archived at ${PHASE2_ARCHIVE}."
fi

# 3. Stop running services to clear VRAM
echo "Stopping active services..."
sudo systemctl stop llama-server.service || true
sudo systemctl stop llama-server-bee.service || true
echo "✓ Services stopped."

# 4. Generate new Phase 3 llama-server.service pointing to BeeLlama on port 8080
echo "Generating new Phase 3 llama-server.service..."
sed -e 's/--port 8082/--port 8080/g' \
    -e 's/loopback-only routing on 127.0.0.1:8082/loopback-only routing on 127.0.0.1:8080/g' \
    "${BEE_UNIT}" > "${CURRENT_UNIT}"
echo "✓ llama-server.service updated for port 8080."

# 5. Install the new systemd unit
echo "Installing updated systemd unit..."
bash scripts/install-systemd.sh

# 6. Restart llama-server under the new configuration
echo "Starting llama-server.service with BeeLlama..."
sudo systemctl start llama-server.service

# 7. Wait for llama-server to be ready (up to 180 seconds)
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
  echo "  Check the systemd journal for errors: journalctl -u llama-server -n 50" >&2
  exit 1
fi

# 8. Point OpenClaw gateway to 8080 and restart gateway
echo "Switching OpenClaw gateway to point to port 8080..."
bash scripts/openclaw-point-at.sh 8080

# 9. Run Phase 3 validation suite on port 8080
echo "=== Running Phase 3 Verification on port 8080 ==="
export LLAMA_URL="http://127.0.0.1:8080"
export LLAMA_PORT="8080"
if bash tests/verify-phase3.sh; then
  echo "✓ Phase 3 Verification PASSED on port 8080."
else
  echo "✗ Error: Phase 3 Verification FAILED on port 8080." >&2
  echo "  Consider rolling back to Phase 2 immediately by running: bash scripts/rollback-to-phase2.sh" >&2
  exit 1
fi

# 10. Run Phase 2 verify suite to ensure no regressions
echo "=== Running Phase 2 Verification checks as regression guard ==="
# Note: we skip throughput in verify-phase2 because we have a different spec-type now
if bash tests/verify-phase2.sh --skip-bench; then
  echo "✓ Phase 2 regression checks passed."
else
  echo "⚠️ Phase 2 regression checks reported issues. Inspect logs." >&2
fi

echo "=== Phase 3 Cutover SUCCESSFUL! ===",path: