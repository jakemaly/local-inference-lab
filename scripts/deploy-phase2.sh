#!/usr/bin/env bash
# Deploy Phase 2: install systemd unit, restart llama + OpenClaw, run verify-phase2.
#
# Requires sudo (writes /etc/systemd/system/llama-server.service).
# Preserves routing: llama stays on 127.0.0.1:8080, OpenClaw on 127.0.0.1:18789.
#
# Usage:
#   bash /home/hermes/llama/scripts/deploy-phase2.sh

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Phase 2 MTP Deploy ==="
echo "1/3 Install Phase 2 systemd unit (requires sudo)"
bash "${ROOT}/scripts/install-systemd.sh"

echo ""
echo "2/3 Restart llama-server + OpenClaw gateway (requires sudo)"
bash /home/hermes/restart-llama-gateway.sh

echo ""
echo "3/3 Run Phase 2 verify suite"
bash "${ROOT}/tests/verify-phase2.sh"

echo ""
echo "=== Phase 2 deploy complete ==="
