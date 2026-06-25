
# We have inference at home
This repository documents the learning, design and evolution of an ongoing local inference machine hosted in my bedroom. It will include write-ups on my notes and processes, sample code, configurations, and benchmarks.

Find the [current stable server config here.](systemd/llama-server.service)

## Hardware

**NVIDIA RTX 3090** (upgraded from RTX 2060)

> *Why the upgrade? The 3090 has 24GB of Video RAM (VRAM), compared to the 2060's 8GB. This makes a world of difference in terms of the model size you can fit on your hardware.*

**Intel i7-9700k, 2x16GB RAM, MSI Z390-A Pro**

> *These are important to keep in the back of the mind, but we want to keep our model running on GPU, not to offload to CPU RAM. This is because the GPU is 22.5x faster than the CPU (936 GB/s vs 41.6 GB/s).*

## Bottleneck 1: Really Big Model Weights

Large language models are pretty large. Claude Fable 5 is estimated with a size of 6T. That's 6 trillion numbers, each representing one weight tuned to influence the model's behaviour. This project uses Qwen3.6 27B, so 27 billion weights.

Without quantization, typical models use 32-bit floating point (FP32) weights. FP32 demands 4 bytes of memory, which adds up quick. Let's see what happens if we use less precise numbers, aka quantization.


| Quantization | Bytes/weight | Size   | Quality       |
| ------------ | ------------ | ------ | ------------- |
| Q4 (INT4)    | 0.5          | ~16GB  | Good          |
| Q8 (INT8)    | 1            | ~29GB  | Near-lossless |
| FP32         | 4            | ~108GB | Lossless      |


By switching to Q4, we represent our weights in INT4 (16 distinct values) rather than FP32 (4 billion distinct values). At runtime, we multiply the INT4 value by the block's scale factor to reconstitute the weight. Quantization allows for faster decoding and lower VRAM requirements, but results in less precision per weight. Now, we can fit a 27B model on our RTX 3090!

## Bottleneck 2: Really Big Context Caches

Models need to remember everything that has been said in a conversation, and that memory comes with a cost.

The [attention mechanism](https://arxiv.org/pdf/1706.03762) for LLMs uses past tokens to decide what's relevant and what isn't.  When generating a new token in sequence, it queries (Q) past tokens whose meanings are stored as a key-value (KV) pair. As we build our context windows, more tokens are added to the storage (KV cache). 

Similarly to weights, KV vectors are very precise. Using a similar quantization strategy (FP32 -> INT4) as we used for the weights, we can avoid overflowing memory and actually run large context windows.

> This setup serving Qwen3.6 27B can effectively run 262k context windows with q4_0. I experimented with TurboQuant, but Qwen + llama.cpp has great cache efficiency with simpler quantizations.

## Bottleneck 3: Kinda Slow Generation Speeds

Language models generate tokens sequentially, known as autoregression.
 - The quick brown *[fox]* ...
 - The quick brown **fox** *[jumps]* ...
 - The quick brown **fox jumps** *[over]*  ...


This is a tad slow, so what can we do?

Imagine you wanted to write an essay, and you recruit your younger, faster brother to put the words to paper.

 Your brother is pretty capable, and he can draft the words you'd *probably* want to write much faster than you could.

 If he writes something you wouldn't at word 4, you just accept what he wrote from words 1-3, and write **>> word4** yourself. 
 
 - The quick brown *[fox jumps over ~~its~~]* ...
 - The quick brown **fox jumps over** ~~its~~  ***>> the***  *[lazy dog]* ...
 - The quick brown **fox jumps over the lazy dog** ✅ 

This is the essence of speculative decoding. Using your base model + a  draft model (smaller, faster model) allows for much faster inference since models can process multiple tokens in parallel, but only generate one at a time.

Multi-token prediction (MTP) bakes the draft model into the base model, sharing the "training knowledge". This is like instead of having your brother write your essay, you have yourself (but younger and faster) write the essay. This makes MTP a great, accurate option for local inference setups.

## Implementation
Replaced RTX 2060 with RTX 3090, installed new PSU (500W -> 1000W)

Experimented with WSL2, decided to dual-boot Linux instead

Installed inference engine ([llama.cpp](https://github.com/ggml-org/llama.cpp) for CUDA) and [downloaded model weights](https://huggingface.co), and wrote config script

Served via Tailscale for SSH from anywhere

Harnessed through [custom Pi setup](https://github.com/jakemaly/pi) for coding

## Experiments and benchmarks

A complete evaluation sweep of Qwen3.6 27B MTP and Gemma 4 31B QAT MTP. Native performance is benched using `llama-bench` (from native llama.cpp build). Agentic capability is evaluated via a 5-instance batch from the **SWE-bench Verified** suite using the `pi` coding harness (with local llama.cpp endpoints).

### 1. Native Llama-bench Performance (tokens/sec)

| Model | Size | pp512 | tg128 | pp512 @ d2000 | tg128 @ d2000 | pp512 @ d4000 | tg128 @ d4000 | pp512 @ d8000 | tg128 @ d8000 |
|---|---|---|---|---|---|---|---|---|---|
| **Qwen3.6 27B MTP** <br>`Qwen3.6-27B-Q4_K_M.gguf` | 15.92 GiB | 1453.93 ± 28.32 | 42.20 ± 0.04 | 1410.03 ± 32.21 | 41.61 ± 0.04 | 1370.06 ± 25.18 | 40.76 ± 0.06 | 1320.93 ± 25.97 | 40.08 ± 0.04 |
| **Gemma 4 31B QAT MTP** <br>`gemma-4-31B-it-qat-UD-Q4_K_XL.gguf` | 16.09 GiB | 1449.61 ± 17.87 | 40.20 ± 0.03 | 1315.79 ± 10.75 | 38.57 ± 0.06 | 1246.64 ± 13.34 | 37.63 ± 0.11 | 1082.30 ± 27.62 | 36.26 ± 0.08 |

*Benchmarked with: `-ngl 99 -fa on -ctk q4_0 -ctv q4_0`*

### 2. SWE-bench Verified Batch Evaluation (5 Instances)

To obtain a more statistically significant capability measurement and avoid single-test bias, we evaluated both models on a batch of 5 instances from the `SWE-bench Verified` suite:
1. `sympy__sympy-20590` (slots regression)
2. `sympy__sympy-24443` (permutation group homomorphism check)
3. `sympy__sympy-13974` (tensor product power evaluation)
4. `sympy__sympy-14248` (matrix symbols difference printer)
5. `sympy__sympy-13877` (matrix determinant NaN comparison Bareiss algorithm)

| Model | Total | Resolved (PASS) | Unresolved (FAIL) | Empty Patch (OOM/Timeout) | Docker Build Error |
|---|---|---|---|---|---|
| **Qwen3.6 27B MTP** | 5 | **1** (`sympy__sympy-24443`) | **1** (`sympy__sympy-13974`) | **2** (`sympy__sympy-13877`, `sympy__sympy-14248`) | **1** (`sympy__sympy-20590`) |
| **Gemma 4 31B QAT MTP** | 5 | **1** (`sympy__sympy-20590`) | **2** (`sympy__sympy-13877`, `sympy__sympy-14248`) | **0** | **2** (`sympy__sympy-13974`, `sympy__sympy-24443`) |

**Key Observations:**
* **Gemma 4 31B QAT MTP** successfully generated patches for all 5 instances without any server-side OOMs or timeouts, showing superior context management stability on the RTX 3090.
* **Qwen3.6 27B MTP** resolved `sympy__sympy-24443` correctly but hit model loading / VRAM context limits resulting in empty predictions (503 timeouts) on two instances.
* Both models struggled to completely resolve complex mathematical logic bugs where multiple files or tests are affected.
* Docker build errors were caused by intermittent IPv6 connection timeouts to Docker Hub during evaluation container image pulls on the host machine.




