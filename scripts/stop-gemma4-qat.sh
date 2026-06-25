#!/usr/bin/env bash
# Stop the Gemma 4 QAT MTP llama-server service.
set -euo pipefail

UNIT_NAME="llama-server-gemma4-qat-mtp"

echo "Stopping ${UNIT_NAME}..."
sudo systemctl stop "${UNIT_NAME}.service" 2>/dev/null || true
echo "✓ ${UNIT_NAME} stopped."
