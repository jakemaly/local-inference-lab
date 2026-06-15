# Gemma 4 — llama.cpp

Gemma 4 models served via mainline llama.cpp on a single RTX 3090 (24 GB).

## Gemma 4 31B QAT MTP (UD-Q4_K_XL + Q4_0 draft)

**Base model:** [unsloth/gemma-4-31B-it-qat-GGUF](https://huggingface.co/unsloth/gemma-4-31B-it-qat-GGUF) — `gemma-4-31B-it-qat-UD-Q4_K_XL.gguf` (16.1 GB).  
**Draft head:** `MTP/gemma-4-31B-it-Q4_0-MTP.gguf` (267 MB) — external MTP nextn drafter.  
**Source:** Google's Quantization-Aware Trained (QAT) Gemma 4 31B, converted to GGUF by Unsloth.  
**Engine:** llama.cpp (mainline, `ggml-org/llama.cpp`) built from source with CUDA.  
**Service:** systemd unit at `systemd/llama-server-gemma4-qat-mtp.service`.

### Quick start

```bash
# 1. Download the GGUF files (~17 GB total)
bash scripts/download-gemma4-qat-mtp.sh

# 2. Start the service
bash scripts/start-gemma4-qat.sh

# 3. Test
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}],"max_tokens":50}'
```

### Stop the service

```bash
bash scripts/stop-gemma4-qat.sh
```

### Configuration

| Parameter | Default | Notes |
|---|---|---|
| Context (`-c`) | 65536 (64K) | Safe on 24 GB. Raise if VRAM margin allows. |
| Batch (`-b`) | 2048 | Prompt-processing batch. |
| Micro-batch (`-ub`) | 512 | Chunked-prefill chunk. |
| KV type | q4_0 K+V | Best context/VRAM trade-off. |
| MTP n | 2 | External draft-mtp via --spec-draft-model. |
| Temperature | 1.0 | Gemma 4 default. |
| Top-p / Top-k | 0.95 / 64 | Gemma 4 defaults. |

### VRAM budget (24 GB RTX 3090)

| Component | Size |
|---|---|
| Base weights (UD-Q4_K_XL) | ~16.1 GB |
| MTP draft head (Q4_0) | ~0.3 GB |
| KV cache at 64K (q4_0) | ~1.5 GB |
| Overhead / activations | ~2-3 GB |
| **Total** | **~19-21 GB** |
