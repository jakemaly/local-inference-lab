#!/usr/bin/env bash
# Download DavidAU Heretic Uncensored Qwen3.6 27B IQ4_NL target model.
#
# Usage:
#   bash /home/hermes/llama/scripts/download-heretic-model.sh

set -euo pipefail

HERETIC_DIR="/home/hermes/llama/models/heretic"
REPO="DavidAU/Qwen3.6-27B-Heretic-Uncensored-FINETUNE-NEO-CODE-Di-IMatrix-MAX-GGUF"
MODEL_FILE="Qwen3.6-27B-NEO-CODE-HERE-2T-OT-IQ4_NL.gguf"

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

echo "=== 2. Creating heretic models directory ==="
mkdir -p "${HERETIC_DIR}"

echo "=== 3. Downloading Heretic IQ4_NL target model ==="
"${HF_CMD}" download "${REPO}" "${MODEL_FILE}" \
  --local-dir "${HERETIC_DIR}"

echo "=== 4. Verification ==="
echo "Checking model file in ${HERETIC_DIR}:"
ls -lh "${HERETIC_DIR}"

if [[ -f "${HERETIC_DIR}/${MODEL_FILE}" ]]; then
  echo "✓ Heretic model successfully downloaded to ${HERETIC_DIR}/${MODEL_FILE}."
else
  echo "✗ Error: Model file missing at ${HERETIC_DIR}/${MODEL_FILE}" >&2
  exit 1
fi
