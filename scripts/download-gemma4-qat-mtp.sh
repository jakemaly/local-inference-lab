#!/usr/bin/env bash
# Download Unsloth Gemma 4 31B QAT MTP model.
# Downloads both the base UD-Q4_K_XL GGUF and the MTP Q4_0 draft head GGUF.
set -euo pipefail

MODEL_DIR="/home/hermes/llama/models/gemma-4-31b-qat-mtp"
REPO="unsloth/gemma-4-31B-it-qat-GGUF"
BASE_FILE="gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"
MTP_FILE="mtp-gemma-4-31B-it.gguf"

mkdir -p "${MODEL_DIR}"

# Ensure hf CLI is available
if ! command -v hf >/dev/null 2>&1; then
  python3 -m pip install --user "huggingface_hub[cli]" --break-system-packages
  export PATH="${HOME}/.local/bin:${PATH}"
fi

echo "Downloading base model (16 GB)..."
hf download "${REPO}" "${BASE_FILE}" --local-dir "${MODEL_DIR}"

echo ""
echo "Downloading MTP draft head (0.3 GB)..."
hf download "${REPO}" "${MTP_FILE}" --local-dir "${MODEL_DIR}"

echo ""
echo "✓ Gemma 4 QAT MTP model downloaded"
ls -lh "${MODEL_DIR}/${BASE_FILE}"
ls -lh "${MODEL_DIR}/${MTP_FILE}"
