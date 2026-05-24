#!/usr/bin/env bash
# Install / refresh the version-controlled llama-server systemd unit.
# Does NOT restart the service — use restart-llama-gateway.sh after install.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="${ROOT}/systemd/llama-server.service"
UNIT_DST="/etc/systemd/system/llama-server.service"
BEE_SRC="${ROOT}/systemd/llama-server-bee.service"
BEE_DST="/etc/systemd/system/llama-server-bee.service"

if [[ ! -f "${UNIT_SRC}" ]]; then
  echo "ERROR: missing ${UNIT_SRC}" >&2
  exit 1
fi

echo "Installing ${UNIT_SRC} -> ${UNIT_DST}"
sudo cp "${UNIT_SRC}" "${UNIT_DST}"

if [[ -f "${BEE_SRC}" ]]; then
  echo "Installing sibling unit ${BEE_SRC} -> ${BEE_DST}"
  sudo cp "${BEE_SRC}" "${BEE_DST}"
fi

sudo systemctl daemon-reload
echo "Done. Reloaded systemd units."

