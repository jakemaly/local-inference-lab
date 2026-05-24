#!/usr/bin/env bash
# Shared helpers for llama-server host tests.
set -euo pipefail

export LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:8080}"
export LLAMA_MODEL="${LLAMA_MODEL:-qwen3.6-27b}"
export OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:18789}"
export PHASE1_CTX="${PHASE1_CTX:-98304}"
export LLAMA_HOST="${LLAMA_HOST:-127.0.0.1}"
export LLAMA_PORT="${LLAMA_PORT:-8080}"
export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; printf "    \033[33m→\033[0m %s\n" "$2"; return 1; }
skip() { printf "  \033[33m⊘\033[0m %s (skipped)\n" "$1"; return 0; }
info() { printf "  \033[2m·\033[0m %s\n" "$1"; }

FAILED=0
run_check() {
  local label="$1"
  shift
  if "$@"; then
    : 
  else
    FAILED=$((FAILED + 1))
  fi
}

curl_json() {
  local method="${1:-GET}"
  local path="$2"
  local data="${3:-}"
  local timeout="${4:-30}"
  if [[ -n "$data" ]]; then
    curl -sf -m "$timeout" -X "$method" "${LLAMA_URL}${path}" \
      -H 'Content-Type: application/json' \
      -d "$data"
  else
    curl -sf -m "$timeout" "${LLAMA_URL}${path}"
  fi
}

chat_completion() {
  local payload="$1"
  local timeout="${2:-60}"
  curl_json POST /v1/chat/completions "$payload" "$timeout"
}

python_analyze() {
  python3 -c "$1"
}
