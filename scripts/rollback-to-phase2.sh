#!/usr/bin/env bash
# Roll back the active llama-server.service and OpenClaw configuration to Phase 2 MTP.
#
# Usage:
#   bash /home/hermes/llama/scripts/rollback-to-phase2.sh

set -euo pipefail

ROOT="/home/hermes/llama"
cd "${ROOT}"

PHASE2_ARCHIVE="${ROOT}/systemd/llama-server-phase2-mtp.service"
CURRENT_UNIT="${ROOT}/systemd/llama-server.service"

echo "=== Rolling Back to Phase 2 MTP ==="

# 1. Check if Phase 2 archive exists
if [[ ! -f "${PHASE2_ARCHIVE}" ]]; then
  echo "✗ Error: Phase 2 archive unit not found at ${PHASE2_ARCHIVE}." >&2
  echo "  Cannot restore Phase 2 MTP service without the archived service unit." >&2
  exit 1
fi

# 2. Restore Phase 2 systemd service file
echo "Restoring systemd unit configuration..."
cp "${PHASE2_ARCHIVE}" "${CURRENT_UNIT}"

# 3. Stop both services to clear VRAM
echo "Stopping any running services..."
sudo systemctl stop llama-server.service || true
sudo systemctl stop llama-server-bee.service || true

# 4. Reinstall systemd unit
echo "Installing Phase 2 unit..."
bash scripts/install-systemd.sh

# 5. Restart llama-server under Phase 2
echo "Starting llama-server.service (Phase 2 MTP)..."
sudo systemctl start llama-server.service

# 6. Wait for llama-server to be ready (up to 180 seconds)
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

# 7. Point OpenClaw gateway back to port 8080
echo "Pointing OpenClaw gateway to port 8080..."
bash scripts/openclaw-point-at.sh 8080

# 8. Run Phase 2 verify suite
echo "=== Running Phase 2 Verification checks ==="
export LLAMA_URL="http://127.0.0.1:8080"
export LLAMA_PORT="8080"
if bash tests/verify-phase2.sh; then
  echo "=== Rollback to Phase 2 MTP Completed SUCCESSFUL === "
  exit 0
else
  echo "✗ Error: Phase 2 verification failed after restore." >&2
  exit 1
fi
