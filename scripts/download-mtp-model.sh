#!/usr/bin/env bash
# Download Unsloth MTP Qwen3.6-27B Q4_K_M model.
#
# Usage:
#   bash /home/hermes/llama/scripts/download-mtp-model.sh

set -euo pipefail

MTP_DIR="/home/hermes/llama/models/unsloth-mtp-q4km"
REPO="unsloth/Qwen3.6-27B-MTP-GGUF"
MODEL_FILE="Qwen3.6-27B-Q4_K_M.gguf"

echo "=== 1. Ensuring environment is ready ==="
if command -v hf >/dev/null 2>&1; then
  HF_CMD="hf"
  echo "✓ Found 'hf' CLI. Using it for download."
else
  HF_CMD="huggingface-cli"
  if ! command -v huggingface-cli >/dev/null 2>&1; then
    echo "huggingface-cli not found. Installing huggingface_hub[cli] via pip3..."
    python3 -m pip install --user "huggingface_hub[cli]" --break-system-packages
    export PATH="${HOME}/.local/bin:${PATH}"
    if ! command -v huggingface-cli >/dev/null 2>&1; then
      echo "Error: huggingface-cli still not found in PATH after installation." >&2
      exit 1
    fi
  fi
  echo "✓ huggingface-cli is available: $(which huggingface-cli)"
fi

echo "=== 2. Creating MTP models directory ==="
mkdir -p "${MTP_DIR}"

echo "=== 3. Downloading MTP Q4_K_M target model ==="
"${HF_CMD}" download "${REPO}" "${MODEL_FILE}" \
  --local-dir "${MTP_DIR}"

echo "=== 4. Verification ==="
echo "Checking model file in ${MTP_DIR}:"
ls -lh "${MTP_DIR}"

if [[ -f "${MTP_DIR}/${MODEL_FILE}" ]]; then
  echo "✓ MTP model successfully downloaded to ${MTP_DIR}/${MODEL_FILE}."
else
  echo "✗ Error: Model file missing at ${MTP_DIR}/${MODEL_FILE}" >&2
  exit 1
fi
