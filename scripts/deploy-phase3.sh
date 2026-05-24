#!/usr/bin/env bash
# Deploy Phase 3 (BeeLlama Precision Combo) in validation mode.
# Build, download models, install unit, stop Phase 2, start and validate BeeLlama,
# then restore Phase 2 so normal operations are not disrupted prior to explicit cutover.
#
# Usage:
#   bash /home/hermes/llama/scripts/deploy-phase3.sh

set -euo pipefail

ROOT="/home/hermes/llama"
cd "${ROOT}"

echo "=== Phase 3 Deploy: Validation Orchestrator ==="

# 1. Build BeeLlama
echo "Step 1: Running build process..."
bash scripts/build-beellama.sh

# 2. Download Models
echo "Step 2: Downloading precision models..."
bash scripts/download-precision-models.sh

# 3. Install systemd units
echo "Step 3: Installing systemd unit files..."
bash scripts/install-systemd.sh

# 4. Stop Phase 2 to free GPU VRAM
echo "Step 4: Stopping active Phase 2 service to free VRAM..."
sudo systemctl stop llama-server.service || true

# 5. Start Phase 3 sibling service on port 8082
echo "Step 5: Starting Phase 3 sibling service (llama-server-bee.service)..."
sudo systemctl start llama-server-bee.service

# 6. Wait for sibling service to be ready
BEE_URL="http://127.0.0.1:8082"
WAIT_SECS=180
echo "⏳ Waiting for BeeLlama to initialize at ${BEE_URL}..."
i=0
ready=0
while (( i < WAIT_SECS )); do
  if curl -sf -m 3 "${BEE_URL}/v1/models" >/dev/null 2>&1; then
    echo "✓ BeeLlama service is ready on port 8082!"
    ready=1
    break
  fi
  sleep 2
  i=$((i + 2))
done

if [[ "$ready" -ne 1 ]]; then
  echo "✗ Error: BeeLlama failed to start within ${WAIT_SECS} seconds." >&2
  echo "  Restoring Phase 2 service..." >&2
  sudo systemctl stop llama-server-bee.service || true
  sudo systemctl start llama-server.service
  echo "  Check the systemd journal for errors: journalctl -u llama-server-bee -n 50" >&2
  exit 1
fi

# 7. Run Phase 3 validation suite
echo "Step 6: Running Phase 3 validation suite on port 8082..."
validation_failed=0
if bash tests/verify-phase3.sh; then
  echo "✓ Phase 3 validation successfully passed!"
else
  echo "✗ Error: Phase 3 validation failed." >&2
  validation_failed=1
fi

# 8. Restore Phase 2 systemd service to running state
echo "Step 7: Restoring system state..."
echo "Stopping BeeLlama on port 8082..."
sudo systemctl stop llama-server-bee.service || true

echo "Restarting main llama-server.service on port 8080 (Phase 2 MTP)..."
sudo systemctl start llama-server.service

# Wait for Phase 2 to be ready
LLAMA_URL="http://127.0.0.1:8080"
echo "⏳ Waiting for Phase 2 MTP to be back online at ${LLAMA_URL}..."
i=0
while (( i < 60 )); do
  if curl -sf -m 3 "${LLAMA_URL}/v1/models" >/dev/null 2>&1; then
    echo "✓ Phase 2 MTP is back online."
    break
  fi
  sleep 2
  i=$((i + 2))
done

if [[ "$validation_failed" -eq 1 ]]; then
  echo "=== Deployment validation FAILED. ==="
  exit 1
fi

echo "=== Deployment validation SUCCESSFUL! ==="
echo "Phase 3 (BeeLlama Precision Combo) is built, downloaded, and fully validated."
echo "Active service is currently back on Phase 2 MTP (port 8080)."
echo ""
echo "To execute the cutover and make Phase 3 active permanently, run:"
echo "  bash scripts/cutover-phase3.sh"
echo ""
