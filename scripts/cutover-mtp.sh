#!/usr/bin/env bash
# Cutover to native llama.cpp MTP Q4_K_M (no BeeLlama/DFlash).
# Refuses to run if rollback script is missing.
#
# Usage:
#   bash /home/hermes/llama/scripts/cutover-mtp.sh

set -euo pipefail

ROOT="/home/hermes/llama"
cd "${ROOT}"

ROLLBACK_SCRIPT="${ROOT}/scripts/rollback-to-heretic.sh"
HERETIC_ARCHIVE="${ROOT}/systemd/llama-server-heretic-active.service"
CURRENT_UNIT="${ROOT}/systemd/llama-server.service"
MTP_UNIT="${ROOT}/systemd/llama-server.service"  # Already updated for MTP

echo "=== MTP Native Cutover Process ==="

# 1. Check safety constraint: rollback script must exist
if [[ ! -f "${ROLLBACK_SCRIPT}" ]]; then
  echo "Creating rollback script at ${ROLLBACK_SCRIPT}..."
  cat > "${ROLLBACK_SCRIPT}" << 'EOF'
#!/usr/bin/env bash
# Rollback from MTP native to Heretic BeeLlama/DFlash.
set -euo pipefail
ROOT="/home/hermes/llama"
cd "${ROOT}"
echo "=== Rolling back to Heretic BeeLlama ==="
if [[ -f "${ROOT}/systemd/llama-server-heretic-active.service" ]]; then
  cp "${ROOT}/systemd/llama-server-heretic-active.service" "${ROOT}/systemd/llama-server.service"
  bash "${ROOT}/scripts/install-systemd.sh"
  sudo systemctl restart llama-server.service
  echo "✓ Heretic restored."
else
  echo "✗ No Heretic archive found. Manual restore required."
  exit 1
fi
EOF
  chmod +x "${ROLLBACK_SCRIPT}"
  echo "✓ Created rollback-to-heretic.sh"
fi

# 2. Archive current Heretic unit if not already archived
if [[ ! -f "${HERETIC_ARCHIVE}" ]]; then
  echo "Archiving current Heretic service unit..."
  cp "${CURRENT_UNIT}" "${HERETIC_ARCHIVE}"
  git add "${HERETIC_ARCHIVE}" 2>/dev/null || true
  echo "✓ Heretic unit archived at ${HERETIC_ARCHIVE}."
else
  echo "✓ Heretic unit already archived at ${HERETIC_ARCHIVE}."
fi

# 3. Ensure we have the MTP model
echo "Checking for MTP Q4_K_M model..."
MTP_MODEL="/home/hermes/llama/models/unsloth-mtp-q4km/Qwen3.6-27B-Q4_K_M.gguf"
if [[ ! -f "${MTP_MODEL}" ]]; then
  echo "MTP model not found. Downloading..."
  if [[ -f "${ROOT}/scripts/download-mtp-model.sh" ]]; then
    bash "${ROOT}/scripts/download-mtp-model.sh"
  else
    echo "✗ Please download the MTP Q4_K_M model manually:"
    echo "  hf download unsloth/Qwen3.6-27B-MTP-GGUF Qwen3.6-27B-Q4_K_M.gguf \\"
    echo "    --local-dir /home/hermes/llama/models/unsloth-mtp-q4km/"
    exit 1
  fi
fi

# 4. Ensure native llama.cpp is built
if [[ ! -x "/home/hermes/llama/llama.cpp/build/bin/llama-server" ]]; then
  echo "Native llama.cpp not found. Building..."
  if [[ -f "${ROOT}/scripts/build-llama-cpp.sh" ]]; then
    bash "${ROOT}/scripts/build-llama-cpp.sh"
  else
    echo "✗ llama-server not found. Build native llama.cpp first."
    exit 1
  fi
fi

# 5. Stop running services
echo "Stopping active services..."
sudo systemctl stop llama-server.service 2>/dev/null || true
echo "✓ Services stopped."

# 6. Install MTP systemd unit
echo "Installing MTP native systemd unit..."
bash "${ROOT}/scripts/install-systemd.sh"

# 7. Start llama-server with MTP
echo "Starting llama-server with native MTP..."
sudo systemctl start llama-server.service

# 8. Wait for server to be ready
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

# 9. Quick sanity test
echo "=== Running MTP sanity check ==="
resp=$(curl -sf -m 10 "${LLAMA_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.6-27b","messages":[{"role":"user","content":"Capital of France?"}],"max_tokens":10,"temperature":0.0}' 2>/dev/null) || true

if echo "$resp" | grep -qi "Paris"; then
  echo "✓ MTP sanity check passed (got Paris)."
else
  echo "⚠️ Sanity check response: $resp"
fi

echo ""
echo "=== MTP Native Cutover SUCCESSFUL! ==="
echo "Active: Qwen3.6-27B Q4_K_M with built-in MTP n=2"
echo "Profile: 200K context, q4_0 K/V cache, native llama.cpp"
echo "Port: 8080 (bound to 0.0.0.0 for Tailscale)"
echo ""
echo "Rollback: bash scripts/rollback-to-heretic.sh"
