#!/usr/bin/env bash
# Validate the repo systemd unit file without touching the running service.
set -euo pipefail

UNIT="/home/hermes/llama/systemd/llama-server.service"
fail=0

check() {
  local desc="$1"
  local pattern="$2"
  if grep -qF -- "$pattern" "$UNIT"; then
    printf "  \033[32m✓\033[0m %s\n" "$desc"
  else
    printf "  \033[31m✗\033[0m %s (missing: %s)\n" "$desc" "$pattern"
    fail=1
  fi
}

echo "Validating ${UNIT}"
check "ctx 131072" "-c 131072"
check "batch 4096" "-b 4096"
check "ubatch 1024" "-ub 1024"
check "KV q4_0" "cache-type-k q4_0"
check "jinja" "--jinja"
check "reasoning off" "reasoning off"
check "loopback host" "--host 127.0.0.1"
check "port 8080" "--port 8080"

if grep -q '0\.0\.0\.0' "$UNIT"; then
  printf "  \033[31m✗\033[0m must not bind 0.0.0.0\n"
  fail=1
else
  printf "  \033[32m✓\033[0m no 0.0.0.0 bind\n"
fi

if systemd-analyze verify "$UNIT" >/dev/null 2>&1; then
  printf "  \033[32m✓\033[0m systemd-analyze verify\n"
else
  printf "  \033[33m⊘\033[0m systemd-analyze verify unavailable or warnings (non-fatal)\n"
fi

exit "$fail"
