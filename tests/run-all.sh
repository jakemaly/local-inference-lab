#!/usr/bin/env bash
# Run all offline + online checks.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0

echo "=== validate-unit-file ==="
bash "${ROOT}/tests/validate-unit-file.sh" || failed=$((failed + 1))

echo ""
if [[ -f "${ROOT}/tests/verify-phase2.sh" ]]; then
  echo "=== verify-phase2 ==="
  bash "${ROOT}/tests/verify-phase2.sh" "$@" || failed=$((failed + 1))
else
  echo "=== verify-phase1 ==="
  bash "${ROOT}/tests/verify-phase1.sh" "$@" || failed=$((failed + 1))
fi

exit "$failed"
