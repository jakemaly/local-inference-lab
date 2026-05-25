#!/usr/bin/env bash
# Deploy Heretic IQ4_NL (BeeLlama + DFlash) in validation mode on port 8082.
# Benchmarks Phase 2 on 8080, validates Heretic, then restores Phase 2.
#
# Usage:
#   bash /home/hermes/llama/scripts/deploy-heretic.sh

set -euo pipefail

ROOT="/home/hermes/llama"
cd "${ROOT}"

measure_throughput() {
  local url="$1"
  python3 - <<PY
import json, time, urllib.request

url = "${url}/v1/chat/completions"
payload = {
    "model": "qwen3.6-27b",
    "messages": [{"role": "user", "content": "Write a Python function that merges two sorted lists. Include docstring."}],
    "max_tokens": 120,
    "temperature": 0.6,
    "stream": False,
}
data = json.dumps(payload).encode("utf-8")
req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
start = time.time()
with urllib.request.urlopen(req, timeout=120) as resp:
    body = json.loads(resp.read().decode("utf-8"))
elapsed = time.time() - start
tokens = body.get("usage", {}).get("completion_tokens", 0)
rate = (tokens / elapsed) if elapsed > 0 and tokens > 0 else 0.0
print(f"{rate:.2f}")
PY
}

echo "=== Heretic Deploy: Validation Orchestrator ==="

# 0. Optional baseline benchmark against active Phase 2 on 8080
PHASE2_URL="http://127.0.0.1:8080"
PHASE2_RATE="n/a"
if curl -sf -m 3 "${PHASE2_URL}/v1/models" >/dev/null 2>&1; then
  echo "Step 0: Benchmarking active Phase 2 MTP on port 8080..."
  if PHASE2_RATE="$(measure_throughput "${PHASE2_URL}" 2>/dev/null)"; then
    echo "  Phase 2 baseline throughput: ${PHASE2_RATE} tok/s"
  else
    PHASE2_RATE="n/a"
    echo "  Phase 2 baseline benchmark skipped (request failed)."
  fi
else
  echo "Step 0: Phase 2 not running on 8080 — skipping baseline benchmark."
fi

# 1. Build BeeLlama
echo "Step 1: Running BeeLlama build..."
bash scripts/build-beellama.sh

# 2. Download Heretic model
echo "Step 2: Downloading Heretic IQ4_NL model..."
bash scripts/download-heretic-model.sh

# 2b. Ensure DFlash drafter exists
DRAFTER="/home/hermes/llama/models/precision/dflash-draft-3.6-q4_k_m.gguf"
if [[ ! -f "${DRAFTER}" ]]; then
  echo "Step 2b: DFlash drafter missing — downloading precision assets..."
  bash scripts/download-precision-models.sh
fi

# 3. Install systemd units
echo "Step 3: Installing systemd unit files..."
bash scripts/install-systemd.sh

# 4. Stop Phase 2 to free GPU VRAM
echo "Step 4: Stopping active Phase 2 service to free VRAM..."
sudo systemctl stop llama-server.service || true
sudo systemctl stop llama-server-bee.service || true

# 5. Start Heretic sibling service on port 8082
echo "Step 5: Starting Heretic sibling service (llama-server-heretic.service)..."
sudo systemctl start llama-server-heretic.service

HERETIC_URL="http://127.0.0.1:8082"
WAIT_SECS=180
echo "⏳ Waiting for Heretic BeeLlama to initialize at ${HERETIC_URL}..."
i=0
ready=0
while (( i < WAIT_SECS )); do
  if curl -sf -m 3 "${HERETIC_URL}/v1/models" >/dev/null 2>&1; then
    echo "✓ Heretic service is ready on port 8082!"
    ready=1
    break
  fi
  sleep 2
  i=$((i + 2))
done

if [[ "$ready" -ne 1 ]]; then
  echo "✗ Error: Heretic failed to start within ${WAIT_SECS} seconds." >&2
  echo "  Restoring Phase 2 service..." >&2
  sudo systemctl stop llama-server-heretic.service || true
  sudo systemctl start llama-server.service
  echo "  Check journal: journalctl -u llama-server-heretic -n 50" >&2
  exit 1
fi

# 6. Run Heretic validation suite
echo "Step 6: Running Heretic validation suite on port 8082..."
validation_failed=0
HERETIC_RATE="n/a"
if bash tests/verify-heretic.sh; then
  echo "✓ Heretic validation successfully passed!"
  if HERETIC_RATE="$(measure_throughput "${HERETIC_URL}" 2>/dev/null)"; then
    echo "  Heretic measured throughput: ${HERETIC_RATE} tok/s"
  fi
else
  echo "✗ Error: Heretic validation failed." >&2
  validation_failed=1
fi

# 7. Restore Phase 2
echo "Step 7: Restoring system state..."
echo "Stopping Heretic on port 8082..."
sudo systemctl stop llama-server-heretic.service || true

echo "Restarting main llama-server.service on port 8080 (Phase 2 MTP)..."
sudo systemctl start llama-server.service

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

echo ""
echo "=== Comparison Summary ==="
printf "  Phase 2 MTP (8080):  %s tok/s\n" "${PHASE2_RATE}"
printf "  Heretic IQ4 (8082):  %s tok/s\n" "${HERETIC_RATE}"
echo ""

if [[ "$validation_failed" -eq 1 ]]; then
  echo "=== Deployment validation FAILED. ==="
  exit 1
fi

echo "=== Deployment validation SUCCESSFUL! ==="
echo "Heretic IQ4_NL is built, downloaded, and fully validated."
echo "Active service is currently back on Phase 2 MTP (port 8080)."
echo ""
echo "To A/B test via OpenClaw before cutover:"
echo "  sudo systemctl start llama-server-heretic.service"
echo "  bash scripts/openclaw-point-heretic.sh 8082"
echo ""
echo "To execute permanent cutover to Heretic on port 8080, run:"
echo "  bash scripts/cutover-heretic.sh"
echo ""
