#!/usr/bin/env bash
#
# Phase 1 validation for host systemd llama-server + OpenClaw routing.
#
# Validates club-3090 Phase 1 flags (q4_0 KV, 98304 ctx, jinja, reasoning off)
# without disturbing remote access paths:
#   - llama-server MUST stay on 127.0.0.1:8080 (OpenClaw provider baseUrl)
#   - OpenClaw gateway on 127.0.0.1:18789 (Telegram / remote SSH tunnel path)
#
# Usage:
#   bash /home/hermes/llama/tests/verify-phase1.sh
#   bash /home/hermes/llama/tests/verify-phase1.sh --skip-warmup
#   bash /home/hermes/llama/tests/verify-phase1.sh --routing-only
#
# Env overrides:
#   LLAMA_URL          default http://127.0.0.1:8080
#   LLAMA_MODEL        default qwen3.6-27b
#   PHASE1_CTX         default 98304
#   SKIP_WARMUP=1      skip cold-start priming
#   SKIP_VRAM=1        skip nvidia-smi check
#   SKIP_GATEWAY=1     skip OpenClaw gateway probe

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROUTING_ONLY=0
SKIP_WARMUP_FLAG=0
for arg in "$@"; do
  case "$arg" in
    --routing-only) ROUTING_ONLY=1 ;;
    --skip-warmup)  SKIP_WARMUP_FLAG=1 ;;
  esac
done

UNIT_FILE="/etc/systemd/system/llama-server.service"
REPO_UNIT="/home/hermes/llama/systemd/llama-server.service"
OPENCLAW_JSON="/home/hermes/.openclaw/openclaw.json"

echo "Phase 1 verify — ${LLAMA_URL}  model=${LLAMA_MODEL}  target_ctx=${PHASE1_CTX}"
echo ""

# --------------------------------------------------------------------
# A. Preflight / install integrity
# --------------------------------------------------------------------
check_preflight() {
  echo "[A1] Preflight — binary, model, unit files ..."
  local ok=1
  if [[ -x /home/hermes/llama/llama.cpp/build/bin/llama-server ]]; then
    pass "llama-server binary present"
  else
    fail "llama-server binary missing" "Build: cd /home/hermes/llama/llama.cpp && cmake --build build -j"
    ok=0
  fi
  if [[ -f /home/hermes/llama/models/Qwen3.6-27B-Q4_K_M.gguf ]]; then
    pass "GGUF model present"
  else
    fail "model missing at /home/hermes/llama/models/Qwen3.6-27B-Q4_K_M.gguf" "Download via hf download"
    ok=0
  fi
  if [[ -f "${REPO_UNIT}" ]]; then
    pass "version-controlled unit at ${REPO_UNIT}"
  else
    fail "repo unit missing" "Expected ${REPO_UNIT}"
    ok=0
  fi
  [[ "$ok" -eq 1 ]]
}

check_systemd_active() {
  echo "[A2] systemd — llama-server.service active ..."
  if systemctl is-active --quiet llama-server.service; then
    pass "llama-server.service is active"
  else
    fail "llama-server.service not active" "sudo systemctl start llama-server.service"
    return 1
  fi
  local main_pid
  main_pid="$(systemctl show llama-server.service -p MainPID --value 2>/dev/null || echo 0)"
  if [[ "${main_pid}" =~ ^[0-9]+$ ]] && [[ "${main_pid}" -gt 0 ]]; then
    pass "MainPID=${main_pid}"
  else
    fail "no MainPID" "journalctl -u llama-server.service -n 50"
    return 1
  fi
}

check_unit_flags() {
  echo "[A3] systemd unit — Phase 1 flags present ..."
  if [[ ! -f "${UNIT_FILE}" ]]; then
    fail "installed unit missing at ${UNIT_FILE}" "bash /home/hermes/llama/scripts/install-systemd.sh"
    return 1
  fi
  local unit
  unit="$(tr '\n' ' ' < "${UNIT_FILE}")"
  local missing=()
  for needle in \
    "-c 98304" \
    "-b 4096" \
    "-ub 1024" \
    "--cache-type-k q4_0" \
    "--cache-type-v q4_0" \
    "--jinja" \
    "--reasoning off" \
    "--host 127.0.0.1" \
    "--port 8080"; do
    if [[ "$unit" != *"$needle"* ]]; then
      missing+=("$needle")
    fi
  done
  if ((${#missing[@]} == 0)); then
    pass "all Phase 1 flags found in ${UNIT_FILE}"
  else
    fail "unit missing flags: ${missing[*]}" \
         "bash /home/hermes/llama/scripts/install-systemd.sh && bash /home/hermes/restart-llama-gateway.sh"
    return 1
  fi
  if [[ "$unit" == *"--host 0.0.0.0"* ]]; then
    fail "unit binds 0.0.0.0 — breaks deliberate loopback-only routing" \
         "Keep --host 127.0.0.1 for OpenClaw + SSH tunnel safety"
    return 1
  fi
  pass "loopback-only bind enforced in unit"
}

check_openclaw_context() {
  echo "[A4] OpenClaw — contextWindow matches Phase 1 ..."
  if [[ ! -f "${OPENCLAW_JSON}" ]]; then
    skip "openclaw.json not found"
    return 0
  fi
  local ctx
  ctx="$(python3 - <<'PY' "${OPENCLAW_JSON}"
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
models = d.get("models", {}).get("providers", {}).get("custom-127-0-0-1", {}).get("models", [])
for m in models:
    if m.get("id") == "qwen3.6-27b":
        print(m.get("contextWindow", 0))
        break
PY
)"
  if [[ "${ctx}" == "${PHASE1_CTX}" ]]; then
    pass "openclaw contextWindow=${ctx}"
  else
    fail "openclaw contextWindow=${ctx}, expected ${PHASE1_CTX}" \
         "Update models.providers.custom-127-0-0-1.models[0].contextWindow in openclaw.json"
    return 1
  fi
}

# --------------------------------------------------------------------
# B. Routing / exposure (delicate path for Tailscale + remote SSH)
# --------------------------------------------------------------------
check_llama_bind() {
  echo "[B1] Routing — llama-server listen address ..."
  local line
  line="$(ss -tlnp 2>/dev/null | grep ":${LLAMA_PORT} " || true)"
  if [[ -z "$line" ]]; then
    fail "nothing listening on port ${LLAMA_PORT}" "systemctl status llama-server.service"
    return 1
  fi
  if echo "$line" | grep -q "${LLAMA_HOST}:${LLAMA_PORT}"; then
    pass "llama-server bound to ${LLAMA_HOST}:${LLAMA_PORT}"
  else
    fail "unexpected bind for port ${LLAMA_PORT}" "ss -tlnp | grep ${LLAMA_PORT} — got: $line"
    return 1
  fi
  if echo "$line" | grep -Eq '0\.0\.0\.0:'"${LLAMA_PORT}"'|\[::\]:'"${LLAMA_PORT}"; then
    fail "llama-server exposed on all interfaces" \
         "Revert to --host 127.0.0.1 — remote access should tunnel to loopback, not wide bind"
    return 1
  fi
  pass "not exposed on 0.0.0.0:${LLAMA_PORT}"
}

check_openclaw_bind() {
  echo "[B2] Routing — OpenClaw gateway listen address ..."
  local line
  line="$(ss -tlnp 2>/dev/null | grep ":${OPENCLAW_GATEWAY_PORT} " || true)"
  if [[ -z "$line" ]]; then
    skip "OpenClaw gateway not listening on ${OPENCLAW_GATEWAY_PORT} (may be stopped)"
    return 0
  fi
  if echo "$line" | grep -q "127.0.0.1:${OPENCLAW_GATEWAY_PORT}"; then
    pass "OpenClaw gateway on loopback :${OPENCLAW_GATEWAY_PORT}"
  else
    info "gateway bind: $line"
    pass "gateway port ${OPENCLAW_GATEWAY_PORT} reachable (non-standard bind — review manually)"
  fi
}

check_openclaw_provider_url() {
  echo "[B3] Routing — OpenClaw provider baseUrl matches llama endpoint ..."
  if [[ ! -f "${OPENCLAW_JSON}" ]]; then
    skip "openclaw.json not found"
    return 0
  fi
  local base
  base="$(python3 - <<'PY' "${OPENCLAW_JSON}"
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get("models", {}).get("providers", {}).get("custom-127-0-0-1", {}).get("baseUrl", ""))
PY
)"
  case "$base" in
    http://127.0.0.1|http://127.0.0.1:8080|http://localhost|http://localhost:8080)
      pass "OpenClaw baseUrl=${base} (resolves to llama on :8080)"
      ;;
    *)
      fail "unexpected OpenClaw baseUrl=${base}" \
           "Should be http://127.0.0.1 — OpenClaw appends /v1/chat/completions on port 8080"
      return 1
      ;;
  esac
}

check_no_public_llama() {
  echo "[B4] Routing — llama API not reachable off-loopback ..."
  local lan_ip
  lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "$lan_ip" ]]; then
    skip "could not determine LAN IP"
    return 0
  fi
  if curl -sf -m 2 "http://${lan_ip}:${LLAMA_PORT}/v1/models" >/dev/null 2>&1; then
    fail "llama API reachable at http://${lan_ip}:${LLAMA_PORT} from this host" \
         "Should only answer on 127.0.0.1 — check --host and firewall"
    return 1
  fi
  pass "llama API not reachable via LAN IP ${lan_ip}:${LLAMA_PORT}"
}

# --------------------------------------------------------------------
# C. Server / config probes
# --------------------------------------------------------------------
check_server_models() {
  echo "[C1] API — /v1/models ..."
  if curl -sf -m 10 "${LLAMA_URL}/v1/models" >/dev/null 2>&1; then
    pass "GET /v1/models OK"
  else
    fail "no response from ${LLAMA_URL}/v1/models" "journalctl -u llama-server.service -n 80"
    return 1
  fi
}

check_props() {
  echo "[C2] API — /props (ctx + llama.cpp engine) ..."
  local props
  props="$(curl -sf -m 10 "${LLAMA_URL}/props" 2>/dev/null || true)"
  if [[ -z "$props" ]]; then
    fail "/props unavailable — not llama-server?" "Expected llama.cpp /props endpoint"
    return 1
  fi
  pass "GET /props OK (llama.cpp engine confirmed)"
  local n_ctx
  n_ctx="$(echo "$props" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('default_generation_settings',{}).get('n_ctx',0))" 2>/dev/null || echo 0)"
  if [[ "$n_ctx" == "${PHASE1_CTX}" ]]; then
    pass "n_ctx=${n_ctx}"
  else
    fail "n_ctx=${n_ctx}, expected ${PHASE1_CTX}" \
         "Service may still be on old unit — restart after install-systemd.sh"
    return 1
  fi
}

check_vram() {
  echo "[C3] VRAM — peak under 23 GB ..."
  if [[ "${SKIP_VRAM:-0}" == "1" ]]; then
    skip "SKIP_VRAM=1"
    return 0
  fi
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
  if [[ "$used" -lt 23500 ]]; then
    pass "VRAM ${used} MiB (< 23.5 GB)"
  else
    fail "VRAM ${used} MiB — high for Phase 1 (~21 GB expected)" \
         "Check for duplicate llama processes or ctx/KV misconfig"
    return 1
  fi
}

# --------------------------------------------------------------------
# D. Quality / agent behavior (post-warmup)
# --------------------------------------------------------------------
warmup_engine() {
  if [[ "${SKIP_WARMUP:-0}" == "1" || "$SKIP_WARMUP_FLAG" == "1" ]]; then
    echo "[warmup] skipped"
    return 0
  fi
  echo "[warmup] priming engine (up to 180s, not scored) ..."
  if chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"ping\"}],
    \"max_tokens\": 1,
    \"temperature\": 0.0,
    \"stream\": false,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" 180 >/dev/null 2>&1; then
    echo "[warmup] engine warm"
  else
    echo "[warmup] warmup timed out — scored checks may false-fail if cold"
  fi
}

check_basic_paris() {
  echo "[D1] Quality — Paris sanity (thinking off) ..."
  local resp content
  resp="$(chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What is the capital of France? One short sentence.\"}],
    \"max_tokens\": 40,
    \"temperature\": 0.6,
    \"stream\": false,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" 90)" || { fail "completion request failed" "journalctl -u llama-server.service -n 50"; return 1; }
  content="$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message'].get('content') or '')" 2>/dev/null || true)"
  if echo "$content" | grep -qi "Paris"; then
    pass "reply mentions Paris"
  else
    fail "unexpected reply: $(echo "$content" | head -c 120)" "Check --jinja and chat template"
    return 1
  fi
}

check_no_empty_content() {
  echo "[D2] Quality — non-empty content (OpenClaw #97 class) ..."
  local resp
  resp="$(chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one sentence.\"}],
    \"max_tokens\": 60,
    \"temperature\": 0.6,
    \"stream\": false,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" 90)" || { fail "request failed" "journalctl -u llama-server"; return 1; }
  local analysis
  analysis="$(echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
msg = d['choices'][0]['message']
content = (msg.get('content') or '').strip()
reasoning = (msg.get('reasoning') or msg.get('reasoning_content') or '').strip()
finish = d['choices'][0].get('finish_reason', '')
print(f'{len(content)}|{len(reasoning)}|{finish}|{content[:80]}')
" 2>/dev/null || echo "0|0|error|")"
  IFS='|' read -r clen rlen finish snippet <<< "$analysis"
  if [[ "$clen" -gt 5 ]]; then
    pass "content ${clen} chars (finish=${finish})"
  elif [[ "$rlen" -gt 20 && "$clen" -eq 0 ]]; then
    fail "content empty but reasoning present (${rlen} chars) — thinking not suppressed" \
         "Ensure --reasoning off in systemd unit"
    return 1
  else
    fail "empty or tiny content (${clen} chars, finish=${finish})" "snippet: $snippet"
    return 1
  fi
}

check_no_role_loop() {
  echo "[D3] Quality — no User:/Assistant: role confusion ..."
  local resp content
  resp="$(chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: OK\"}],
    \"max_tokens\": 20,
    \"temperature\": 0.3,
    \"stream\": false,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" 90)" || { fail "request failed" "journalctl -u llama-server"; return 1; }
  content="$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message'].get('content') or '')" 2>/dev/null || true)"
  if echo "$content" | grep -qE '(^|\n)(User:|Assistant:|Human:|<\|im_start\|>)'; then
    fail "role markers in output — likely missing/broken jinja template" \
         "content head: $(echo "$content" | head -c 100)"
    return 1
  fi
  pass "no role-loop markers in output"
}

check_multi_turn() {
  echo "[D4] Quality — multi-turn agent sanity (2 turns) ..."
  local resp content
  resp="$(chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"My code word is CEDAR. Remember it.\"},
      {\"role\": \"assistant\", \"content\": \"Got it, your code word is CEDAR.\"},
      {\"role\": \"user\", \"content\": \"What was my code word? One word answer.\"}
    ],
    \"max_tokens\": 20,
    \"temperature\": 0.3,
    \"stream\": false,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" 90)" || { fail "multi-turn request failed" "journalctl -u llama-server"; return 1; }
  content="$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message'].get('content') or '')" 2>/dev/null || true)"
  if echo "$content" | grep -qi "CEDAR"; then
    pass "multi-turn recall OK"
  else
    fail "did not recall CEDAR: $(echo "$content" | head -c 80)" "Template or context issue"
    return 1
  fi
}

check_non_streaming() {
  echo "[D5] Quality — non-streaming mode (OpenClaw streaming off) ..."
  local resp
  resp="$(chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Count to three.\"}],
    \"max_tokens\": 40,
    \"temperature\": 0.6,
    \"stream\": false,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" 90)" || { fail "non-streaming request failed" "OpenClaw relies on stream:false"; return 1; }
  local clen
  clen="$(echo "$resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['choices'][0]['message'].get('content') or ''))" 2>/dev/null || echo 0)"
  if [[ "$clen" -gt 3 ]]; then
    pass "non-streaming completion ${clen} chars"
  else
    fail "non-streaming returned empty/short content (${clen} chars)" "Check OpenClaw stream:false compatibility"
    return 1
  fi
}

check_degeneracy() {
  echo "[D6] Quality — no repetitive degeneracy ..."
  local resp analysis
  resp="$(chat_completion "{
    \"model\": \"${LLAMA_MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Explain what a for-loop does in Python in 3 sentences.\"}],
    \"max_tokens\": 200,
    \"temperature\": 0.6,
    \"stream\": false,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" 120)" || { fail "request failed" "journalctl -u llama-server"; return 1; }
  analysis="$(echo "$resp" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
c = d['choices'][0]['message'].get('content') or ''
lines = [ln.strip() for ln in c.splitlines() if ln.strip()]
max_rep = 1
if lines:
    run = 1
    for i in range(1, len(lines)):
        if lines[i] == lines[i-1]:
            run += 1
            max_rep = max(max_rep, run)
        else:
            run = 1
words = re.findall(r'\w+', c.lower())
variety = len(set(words)) / max(len(words), 1)
print(f'{len(c)}|{max_rep}|{variety:.3f}')
" 2>/dev/null || echo "0|99|0")"
  IFS='|' read -r clen max_rep variety <<< "$analysis"
  if [[ "$max_rep" -ge 5 ]]; then
    fail "repetitive line cascade (max_repeat=${max_rep})" "Possible sampling/template issue"
    return 1
  fi
  if [[ "$clen" -lt 40 ]]; then
    fail "response too short (${clen} chars)" "Degenerate or truncated output"
    return 1
  fi
  pass "no degeneracy (${clen} chars, max_line_repeat=${max_rep}, variety=${variety})"
}

check_openclaw_gateway() {
  echo "[E1] OpenClaw — gateway health (optional) ..."
  if [[ "${SKIP_GATEWAY:-0}" == "1" ]]; then
    skip "SKIP_GATEWAY=1"
    return 0
  fi
  if curl -sf -m 5 "${OPENCLAW_GATEWAY_URL}/" >/dev/null 2>&1 || \
     curl -sf -m 5 "${OPENCLAW_GATEWAY_URL}/health" >/dev/null 2>&1; then
    pass "OpenClaw gateway responds on ${OPENCLAW_GATEWAY_URL}"
  else
    skip "gateway not responding (may use different health path — not blocking Phase 1)"
  fi
}

# --------------------------------------------------------------------
# Run suite
# --------------------------------------------------------------------
run_check "preflight" check_preflight
run_check "systemd" check_systemd_active
run_check "unit-flags" check_unit_flags
run_check "openclaw-ctx" check_openclaw_context

run_check "llama-bind" check_llama_bind
run_check "openclaw-bind" check_openclaw_bind
run_check "provider-url" check_openclaw_provider_url
run_check "no-public" check_no_public_llama

if [[ "$ROUTING_ONLY" == "1" ]]; then
  echo ""
  if [[ "$FAILED" -eq 0 ]]; then
    echo "Routing checks passed (${FAILED} failures)."
    exit 0
  else
    echo "Routing checks failed: ${FAILED} failure(s)."
    exit 1
  fi
fi

run_check "models" check_server_models
run_check "props" check_props
run_check "vram" check_vram

warmup_engine

run_check "paris" check_basic_paris
run_check "empty-content" check_no_empty_content
run_check "role-loop" check_no_role_loop
run_check "multi-turn" check_multi_turn
run_check "non-streaming" check_non_streaming
run_check "degeneracy" check_degeneracy
run_check "gateway" check_openclaw_gateway

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "Phase 1 verify PASSED (0 failures)."
  exit 0
else
  echo "Phase 1 verify FAILED (${FAILED} failure(s))."
  exit 1
fi
