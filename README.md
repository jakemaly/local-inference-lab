
# We have inference at home

A reproducible local AI infrastructure project exploring high-performance inference, autonomous agent workflows, memory systems, and remote development on consumer hardware. 

### What is this?

This repository documents the learning, design and evolution of an ongoing local inference machine hosted in my bedroom. It will include write-ups on my notes and processes, sample code, configurations, and benchmarks.

Find the [current stable server config here.](systemd/llama-server.service)

## Hardware

**NVIDIA RTX 3090** (upgraded from RTX 2060)

> *Why the upgrade? The 3090 has 24GB of Video RAM (VRAM), compared to the 2060's 8GB. This makes a world of difference in terms of the model size you can fit on your hardware.*

**Intel i7-9700k, 2x16GB RAM, MSI Z390-A Pro**

> *These are important to keep in the back of the mind, but we want to keep our model running on GPU, not to offload to CPU RAM. This is because the GPU is 22.5x faster than the CPU (936 GB/s vs 41.6 GB/s).*

## Bottleneck 1: Really Big Model Weights

Without quantization, typical models use 32-bit floating point (FP32) parameters. FP32 demands 4 bytes of memory, which adds up quick. Let's see what quantization has to offer. 


| Quantization | Bytes/weight | Size   | Quality       |
| ------------ | ------------ | ------ | ------------- |
| Q4 (INT4)    | 0.5          | ~16GB  | Good          |
| Q8 (INT8)    | 1            | ~29GB  | Near-lossless |
| FP32         | 4            | ~108GB | Lossless      |


By switching to Q4, we represent our weights in INT4 (16 distinct values) rather than FP32 (4 billion distinct values). At runtime, we multiply the INT4 value by the block's scale factor to reconstitute the weight. Quantization allows for faster decoding and lower VRAM requirements, but results in less precision per weight. Now, we can fit a 27B model on our RTX 3090!

## Bottleneck 2: Really Big Context Overflow

The [attention mechanism](https://arxiv.org/pdf/1706.03762) for LLMs uses past tokens to decide what's relevant and what isn't.  When generating a new token in sequence, it queries (Q) past tokens whose meanings are stored as a key-value (KV) pair. As we build our context windows, more tokens are added to the storage (KV cache). 

Similarly to weights, KV vectors are rich. Using a similar quantization strategy (FP32 -> INT4) as we used for the weights, we can avoid overflowing memory and actually run large context windows.

> This setup serving Qwen3.6 27B can effectively run 262k context windows with q4_0. I experimented with TurboQuant, but Qwen + llama.cpp has great cache efficiency with simpler quantizations.

## Bottleneck 3: Kinda Slow Generation Speeds

Language models generate tokens sequentially, known as autoregression.
 - The quick brown *[fox]*
 - The quick brown **fox** *[jumps]*
 - The quick brown **fox jumps** *[over]* 


This is a tad slow, so what can we do?

Imagine you wanted to write an essay, and you recruit your younger, faster brother to put the words to paper.

 Your brother is pretty capable, and he can draft the words you'd *probably* want to write much faster than you could.

 If he writes something you wouldn't at word 4, you just accept what he wrote from words 1-3, and write word 4 yourself. 
 
 - The quick brown *[fox jumps over ~~its~~]* 
 - The quick brown **fox jumps over** ~~its~~  ***the ✍️***  *[lazy dog]* 
 - The quick brown **fox jumps over the lazy dog** 

This is the essence of speculative decoding. Using your base model + a  draft model (smaller, faster model) allows for much faster inference since models can process multiple tokens in parallel, but only generate one at a time.

Multi-token prediction (MTP) bakes the draft model into the base model, sharing the "training knowledge". This is like instead of having your brother write your essay, you have yourself (but younger and faster) write the essay. This makes MTP a great, accurate option for local inference setups.

## Implementation

## What I learned

## Experiments and benchmarks

