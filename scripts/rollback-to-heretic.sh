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
