#!/usr/bin/env bash
# Build BeeLlama.cpp with CUDA, FA, and TurboQuant/TCQ cache support.
#
# Usage:
#   bash /home/hermes/llama/scripts/build-beellama.sh

set -euo pipefail

ROOT="/home/hermes/llama"
BEE_DIR="${ROOT}/beellama.cpp"
REPO_URL="https://github.com/Anbeeld/beellama.cpp"
TAG="v0.2.0"

echo "=== 1. Cloning/checking out BeeLlama.cpp (${TAG}) ==="
if [[ ! -d "${BEE_DIR}" ]]; then
  echo "Cloning ${REPO_URL} into ${BEE_DIR}..."
  git clone --depth 1 --branch "${TAG}" "${REPO_URL}" "${BEE_DIR}"
else
  echo "BeeLlama.cpp directory already exists at ${BEE_DIR}. Ensuring correct tag..."
  cd "${BEE_DIR}"
  git fetch --tags
  git checkout "${TAG}"
fi

echo "=== 2. Configuring and building with CMake ==="
cd "${BEE_DIR}"

# Run cmake configuration
# GGML_CUDA_FA_ALL_QUANTS=ON is critical for TurboQuant/TCQ cache types.
# CMAKE_CUDA_ARCHITECTURES=86 is the architecture for RTX 3090.
cmake -B build \
  -DGGML_CUDA=ON \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DGGML_NATIVE=ON \
  -DCMAKE_CUDA_ARCHITECTURES=86 \
  -DCMAKE_BUILD_TYPE=Release

# Build targets in parallel
echo "Building BeeLlama.cpp..."
cmake --build build -j"$(nproc)"

echo "=== 3. Verification of build ==="
if [[ -x "${BEE_DIR}/build/bin/llama-server" ]]; then
  echo "✓ BeeLlama llama-server compiled successfully at ${BEE_DIR}/build/bin/llama-server"
else
  echo "✗ Error: llama-server executable not found at ${BEE_DIR}/build/bin/llama-server" >&2
  exit 1
fi

echo "✓ BeeLlama build process complete."
