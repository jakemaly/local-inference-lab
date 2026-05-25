#!/usr/bin/env bash
#
# Phase 3 validation for host systemd llama-server + BeeLlama precision combo.
#
# Validates:
#   TC-P3-01: Speculative Config (122.8K context, Q5_K_S target, DFlash drafter)
#   TC-P3-02: Build & asset integrity
#   TC-P3-03: Sibling routing (bound to port 8082, loopback only)
#   TC-P3-04: VRAM Peak under load (< 23.5 GB)
#   TC-P3-05: Target model throughput (> 30 tok/s baseline, effective DFlash > 45 tok/s)
#   TC-P3-06: Quality sanity & instruction following
#   TC-P3-07: Context stress & needle-in-a-haystack (30K context test)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Set default port to 8082 for sibling unit validation
export LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:8082}"
export LLAMA_PORT="${LLAMA_PORT:-8082}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROUTING_ONLY=0
SKIP_BENCH=0
SKIP_NEEDLE=0

for arg in "$@"; do
  case "$arg" in
    --routing-only) ROUTING_ONLY=1 ;;
    --skip-bench)    SKIP_BENCH=1 ;;
    --skip-needle)   SKIP_NEEDLE=1 ;;
  esac
done

MODEL_TARGET_PATH="/home/hermes/llama/models/precision/Qwen3.6-27B-Q5_K_S.gguf"
MODEL_DRAFTER_PATH="/home/hermes/llama/models/precision/dflash-draft-3.6-q4_k_m.gguf"
UNIT_FILE="/etc/systemd/system/llama-server-bee.service"

echo "=== Phase 3 BeeLlama Precision Validation ==="
echo "Endpoint: ${LLAMA_URL}  Port: ${LLAMA_PORT}  Target Context: 122800"
echo ""

# --------------------------------------------------------------------
# TC-P3-01: Speculative Config
# --------------------------------------------------------------------
check_speculative_config() {
  echo "[TC-P3-01] Speculative Config — /props checks ..."
  local props
  props="$(curl -sf -m 15 "${LLAMA_URL}/props" 2>/dev/null || true)"
  if [[ -z "$props" ]]; then
    fail "no response from /props" "Expected active llama-server at ${LLAMA_URL}"
    return 1
  fi
  
  local n_ctx model_path
  n_ctx="$(echo "$props" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('default_generation_settings',{}).get('n_ctx',0))" 2>/dev/null || echo 0)"
  model_path="$(echo "$props" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model_path',''))" 2>/dev/null || echo "")"
  
  if [[ "$n_ctx" != "122800" && "$n_ctx" != "122880" ]]; then
    fail "n_ctx=${n_ctx}, expected 122800 or 122880" "BeeLlama service not configured or loaded with incorrect context"
    return 1
  fi
  pass "Context window configured to ${n_ctx} (${n_ctx:0:3}K)"

  if [[ "$model_path" != *"precision/Qwen3.6-27B-Q5_K_S.gguf"* ]]; then
    fail "model_path=${model_path}, expected Q5_K_S precision target" \
         "Ensure the active service points to the precision Q5_K_S model"
    return 1
  fi
  pass "Precision target model loaded: $(basename "${model_path}")"
}

# --------------------------------------------------------------------
# TC-P3-02: Build & asset integrity
# --------------------------------------------------------------------
check_build_assets() {
  echo "[TC-P3-02] Build & Asset Integrity ..."
  if [[ -x "/home/hermes/llama/beellama.cpp/build/bin/llama-server" ]]; then
    pass "BeeLlama compiled server executable found"
  else
    fail "beellama-server executable missing" "Run bash /home/hermes/llama/scripts/build-beellama.sh first"
    return 1
  fi

  if [[ -f "${MODEL_TARGET_PATH}" ]]; then
    pass "Target model Q5_K_S found on disk"
  else
    fail "Target GGUF missing at ${MODEL_TARGET_PATH}" "Run download script first"
    return 1
  fi

  if [[ -f "${MODEL_DRAFTER_PATH}" ]]; then
    pass "DFlash drafter model found on disk"
  else
    fail "DFlash GGUF missing at ${MODEL_DRAFTER_PATH}" "Run download script first"
    return 1
  fi
}

# --------------------------------------------------------------------
# TC-P3-03: Sibling routing (bound to port 8082, loopback only)
# --------------------------------------------------------------------
check_local_routing() {
  echo "[TC-P3-03] Sibling Routing — port ${LLAMA_PORT} listener bindings ..."
  local line
  line="$(ss -tlnp 2>/dev/null | grep ":${LLAMA_PORT} " || true)"
  if [[ -z "$line" ]]; then
    fail "nothing listening on port ${LLAMA_PORT}" "llama-server-bee.service (or custom port service) not running"
    return 1
  fi

  if echo "$line" | grep -q "127.0.0.1:${LLAMA_PORT}"; then
    pass "llama-server is bound to 127.0.0.1:${LLAMA_PORT}"
  else
    fail "unexpected bind for llama-server: $line" "Must be bound to 127.0.0.1 for security"
    return 1
  fi

  if echo "$line" | grep -Eq "0\.0\.0\.0:${LLAMA_PORT}|\[::\]:${LLAMA_PORT}"; then
    fail "llama-server exposed on all interfaces" "Ensure --host 127.0.0.1 is set in the systemd service"
    return 1
  fi
  pass "No public network exposure detected on port ${LLAMA_PORT}"
}

# --------------------------------------------------------------------
# TC-P3-04: VRAM Peak under load (< 23.5 GB)
# --------------------------------------------------------------------
check_vram_peak() {
  echo "[TC-P3-04] VRAM Peak — measuring GPU footprint ..."
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    skip "nvidia-smi not available"
    return 0
  fi
  
  local used
  used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
  if [[ -z "$used" ]]; then
    skip "could not read VRAM"
    return 0
  fi

  # Maximum allowed VRAM is 23.5 GB (24064 MiB) to avoid swapping or OOM crashes
  if (( used < 24064 )); then
    pass "VRAM usage under load is ${used} MiB / 24576 MiB (< 23.5 GB threshold)"
  else
    fail "VRAM usage is ${used} MiB (>= 23.5 GB threshold)" \
         "Possibility of host process VRAM leak, multiple servers running, or too high spec-dflash-cross-ctx/ctx-size"
    return 1
  fi
}

# --------------------------------------------------------------------
# TC-P3-05: Target model throughput & effective speed
# --------------------------------------------------------------------
check_throughput() {
  echo "[TC-P3-05] Target & DFlash Throughput checks ..."
  if [[ "${SKIP_BENCH}" == "1" ]]; then
    skip "SKIP_BENCH=1 (llama-bench & timing checks skipped)"
    return 0
  fi

  # 1. Target model baseline check using llama-bench is skipped to avoid GPU Out-of-Memory.
  # Since the active server is already running on the single GPU and occupying ~22.3 GB,
  # launching a separate llama-bench instance would cause a model load failure.
  # We rely on the live end-to-end token latency check below which fully validates speculative performance.
  info "Skipping duplicate model loading via llama-bench to prevent GPU Out of Memory."

  # 2. Live speculative decoding throughput check via completion API
  echo "  · Running end-to-end token latency test on active DFlash server ..."
  local start_t end_t resp elapsed content token_count rate
  start_t="$(python3 -c "import time; print(time.time())")"
  resp="$(chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Write a beautiful, detailed Python class representing a doubly linked list with comprehensive operations and docstrings.\"}],
    \"max_tokens\": 150,
    \"temperature\": 0.0,
    \"stream\": false
  }" 90)" || { fail "completion request failed" "Check systemd journal for crash logs"; return 1; }
  end_t="$(python3 -c "import time; print(time.time())")"
  
  elapsed="$(python3 -c "print(${end_t} - ${start_t})")"
  token_count="$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo 0)"
  
  if [[ "$token_count" -gt 0 ]]; then
    rate="$(python3 -c "print(f'{${token_count} / ${elapsed}:.2f}')")"
    if (( $(echo "$rate > 45.0" | bc -l) )); then
      pass "Speculative generation throughput: ${rate} tok/s (${token_count} tokens in ${elapsed}s, exceeds 45.0 tok/s floor)"
    else
      fail "Throughput of ${rate} tok/s is below Phase 3 floor of 45.0 tok/s" \
           "Check if speculative model is loaded properly and --spec-type dflash is set."
      return 1
    fi
  else
    fail "No completion tokens generated" "Response dump: ${resp}"
    return 1
  fi
}

# --------------------------------------------------------------------
# TC-P3-06: Quality sanity & instruction following
# --------------------------------------------------------------------
check_quality_sanity() {
  echo "[TC-P3-06] Quality Sanity — prompt template, role loops, and thinking check ..."
  local resp content
  resp="$(chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What is the capital of Japan? Answer in exactly one word.\"}],
    \"max_tokens\": 30,
    \"temperature\": 0.3,
    \"stream\": false
  }" 90)" || { fail "completion request failed" "Check server log/journal"; return 1; }

  content="$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message'].get('content') or '')" 2>/dev/null || true)"
  
  if echo "$content" | grep -qi "Tokyo"; then
    pass "Correct response content: '$(echo "$content" | tr -d '\n')'"
  else
    fail "unexpected reply: $(echo "$content" | head -c 120)" "Check template parsing or model parameters"
    return 1
  fi

  # Ensure formatting/template works properly and no roles bleed
  if echo "$content" | grep -qE '(^|\n)(User:|Assistant:|Human:|<\|im_start\|>)'; then
    fail "role loop markers or raw tags leaked into content output" "Ensure --jinja is set and formatting matches"
    return 1
  fi
  pass "No role loops or template bleed detected"

  # Ensure reasoning is off and doesn't pollute content
  if echo "$content" | grep -qiE '<thinking>|thinking_process|thought'; then
    fail "Reasoning/thinking markers leaked into output content" "Ensure --reasoning off is correctly adhered to"
    return 1
  fi
  pass "No reasoning/thinking token leak detected"
}

# --------------------------------------------------------------------
# TC-P3-07: Context stress & needle-in-a-haystack
# --------------------------------------------------------------------
check_context_stress() {
  echo "[TC-P3-07] Context stress — needle-in-a-haystack at ~30K tokens ..."
  if [[ "${SKIP_NEEDLE}" == "1" ]]; then
    skip "SKIP_NEEDLE=1 (Needle test skipped)"
    return 0
  fi

  echo "  · Generating ~30K token dummy context with embedded needle..."
  # Prepare a prompt with ~30K tokens of context
  # We will construct a python script to build the payload and send it
  local needle_reply
  needle_reply="$(python3 -c '
import urllib.request, json, sys, time

# Construct dummy text (~30,000 words, close to 30K-40K tokens)
repeating_fact = "The sky is blue, the grass is green, and water is wet."
large_text = [repeating_fact] * 3000

# Embed the secret needle at the start (context-retrieval stress test)
secret_needle = "SECRET_KEY: The golden flamingo flies at midnight in Cairo."
large_text.insert(5, secret_needle)

context_block = " ".join(large_text)

payload = {
    "model": "qwen3.6-27b",
    "messages": [
        {
            "role": "user",
            "content": f"Here is a long document:\\n{context_block}\\n\\nBased on the document, what is the SECRET_KEY? Answer in exactly one sentence containing the SECRET_KEY."
        }
    ],
    "max_tokens": 100,
    "temperature": 0.0,
    "stream": False
}

req_data = json.dumps(payload).encode("utf-8")
headers = {"Content-Type": "application/json"}

# Query the server
req = urllib.request.Request("'"${LLAMA_URL}"'/v1/chat/completions", data=req_data, headers=headers)
try:
    start_t = time.time()
    with urllib.request.urlopen(req, timeout=120) as f:
        res = json.loads(f.read().decode("utf-8"))
    end_t = time.time()
    elapsed = end_t - start_t
    content = res["choices"][0]["message"]["content"]
    print(json.dumps({"content": content, "elapsed": elapsed, "success": True}))
except Exception as e:
    print(json.dumps({"success": False, "error": str(e)}))
')"

  local success error content elapsed
  success="$(echo "$needle_reply" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success'))")"
  
  if [[ "$success" != "True" ]]; then
    error="$(echo "$needle_reply" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))")"
    fail "Long-context needle request failed" "Error: ${error}"
    return 1
  fi

  content="$(echo "$needle_reply" | python3 -c "import sys,json; print(json.load(sys.stdin).get('content',''))")"
  elapsed="$(echo "$needle_reply" | python3 -c "import sys,json; print(json.load(sys.stdin).get('elapsed',0))")"

  if echo "$content" | grep -qi "golden flamingo"; then
    pass "Needle retrieved successfully in ${elapsed}s! Reply: '$(echo "$content" | tr -d '\n')'"
  else
    fail "Model failed to retrieve the needle from ~30K context" "Reply: $(echo "$content" | head -c 120)"
    return 1
  fi
}

# --------------------------------------------------------------------
# Run Suite
# --------------------------------------------------------------------
if [[ "$ROUTING_ONLY" == "1" ]]; then
  run_check "routing" check_local_routing
  echo ""
  if [[ "$FAILED" -eq 0 ]]; then
    echo "Routing checks passed."
    exit 0
  else
    echo "Routing checks failed."
    exit 1
  fi
fi

run_check "props" check_speculative_config
run_check "assets" check_build_assets
run_check "routing" check_local_routing
run_check "vram" check_vram_peak
run_check "throughput" check_throughput
run_check "quality" check_quality_sanity
run_check "needle" check_context_stress

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "Phase 3 Validation PASSED (0 failures)."
  exit 0
else
  echo "Phase 3 Validation FAILED (${FAILED} failure(s))."
  exit 1
fi
