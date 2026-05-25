#!/usr/bin/env bash
# Download Qwen 3.6 27B Q5_K_S target model and Q4_K_M DFlash drafter.
#
# Usage:
#   bash /home/hermes/llama/scripts/download-precision-models.sh

set -euo pipefail

PRECISION_DIR="/home/hermes/llama/models/precision"

echo "=== 1. Ensuring environment is ready ==="
if command -v hf >/dev/null 2>&1; then
  HF_CMD="hf"
  echo "✓ Found custom 'hf' CLI wrapper. Using 'hf' for downloading."
else
  HF_CMD="huggingface-cli"
  if ! command -v huggingface-cli >/dev/null 2>&1; then
    echo "huggingface-cli not found. Installing huggingface_hub[cli] via pip3..."
    python3 -m pip install --user "huggingface_hub[cli]" --break-system-packages
    
    # Ensure user's local bin is in PATH
    export PATH="${HOME}/.local/bin:${PATH}"
    if ! command -v huggingface-cli >/dev/null 2>&1; then
      echo "Error: huggingface-cli still not found in PATH after installation." >&2
      exit 1
    fi
  fi
  echo "✓ huggingface-cli is available: $(which huggingface-cli)"
fi

echo "=== 2. Creating precision models directory ==="
mkdir -p "${PRECISION_DIR}"

echo "=== 3. Downloading Q5_K_S target model ==="
# Download Qwen3.6-27B-Q5_K_S.gguf from unsloth/Qwen3.6-27B-GGUF
"${HF_CMD}" download unsloth/Qwen3.6-27B-GGUF Qwen3.6-27B-Q5_K_S.gguf \
  --local-dir "${PRECISION_DIR}"

echo "=== 4. Downloading Q4_K_M DFlash drafter model ==="
# Download Qwen3.6-27B-DFlash-Q4_K_M.gguf from spiritbuun/Qwen3.6-27B-DFlash-GGUF
"${HF_CMD}" download spiritbuun/Qwen3.6-27B-DFlash-GGUF Qwen3.6-27B-DFlash-Q4_K_M.gguf \
  --local-dir "${PRECISION_DIR}"

echo "=== 5. Verification ==="
echo "Checking model files in ${PRECISION_DIR}:"
ls -lh "${PRECISION_DIR}"

if [[ -f "${PRECISION_DIR}/Qwen3.6-27B-Q5_K_S.gguf" && -f "${PRECISION_DIR}/Qwen3.6-27B-DFlash-Q4_K_M.gguf" ]]; then
  echo "✓ Both models successfully downloaded to ${PRECISION_DIR}."
else
  echo "✗ Error: One or more model files are missing." >&2
  exit 1
fi
