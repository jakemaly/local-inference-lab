#!/usr/bin/env bash
# Deploy Phase 1: install systemd unit, restart llama + OpenClaw, run verify.
#
# Requires sudo (writes /etc/systemd/system/llama-server.service).
# Preserves routing: llama stays on 127.0.0.1:8080, OpenClaw on 127.0.0.1:18789.
#
# Usage:
#   bash /home/hermes/llama/scripts/deploy-phase1.sh
#   RUN_VERIFY=0 bash /home/hermes/llama/scripts/deploy-phase1.sh   # skip post-restart tests

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Phase 1 deploy ==="
echo "1/3 Install systemd unit"
bash "${ROOT}/scripts/install-systemd.sh"

echo ""
echo "2/3 Restart llama-server + OpenClaw gateway"
bash /home/hermes/restart-llama-gateway.sh

echo ""
echo "3/3 Full Phase 1 verify (includes warmup)"
bash "${ROOT}/tests/verify-phase1.sh"

echo ""
echo "=== Phase 1 deploy complete ==="
