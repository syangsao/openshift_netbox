# RTX 3090 — Single GPU Deployment

This guide covers deploying Qwen3.6-27B on a single RTX 3090 (24GB VRAM) using either **vLLM** (speed-focused) or **llama.cpp** (high context + vision).

Based on benchmarks from [club-3090 discussion #152](https://github.com/noonghunna/club-3090/discussions/152).

---

## GPU Setup — Undervolt & Overclock

Before running the model, optimize your GPU for efficiency and performance.

### Quick Start

```bash
sudo bash scripts/3090-gpu-setup.sh
```

This script:
1. Enables persistence mode
2. Sets power limit to **250W** (down from 350W TDP)
3. Locks GPU core clocks to **1850MHz**
4. Applies **+200MHz** core overclock
5. Applies **+1000MHz** memory overclock

### What it does

The script runs a Python NVML program inside an ephemeral Docker container to apply settings without installing `nvidia-ml-py` on the host.

### Verify

```bash
nvidia-smi -q | grep -E 'Power|Clock|Offset'
```

### Notes

- These settings are **not persistent across reboots** — re-run after reboot
- The +1000MHz memory overclock is the "performance consensus" for Ampere 3090s
- If you experience instability, reduce the memory offset to +500MHz
- The original script from the discussion configured two GPUs (3090 + 5060 Ti) — this version is for a single 3090 only

---

## Option A: vLLM + PIECEWISE + MTP (Speed)

**Best for:** Maximum throughput, 70-80 tps, 65k context window

### Benchmarks

| Metric | Value |
|---|---|
| Mean TPS | 80.3 |
| Max TPS | 103.9 |
| Quality Score | 0.97 |
| Context Window | 65k tokens |

### Docker Compose

```yaml
services:
  vllm-qwen36-turbo:
    image: vllm/vllm-openai:v0.20.0
    container_name: vllm-qwen3.6-27b
    runtime: nvidia
    restart: unless-stopped
    shm_size: "16gb"
    ipc: host
    ports:
      - "8787:8000"
    volumes:
      - /path/to/model/qwen3.6-27b-autoround-int4:/model:ro
      - /path/to/vendor-patches:/vendor:ro
    environment:
      - CUDA_DEVICE_ORDER=PCI_BUS_ID
      - NVIDIA_VISIBLE_DEVICES=0
      - NVIDIA_DRIVER_CAPABILITIES=all
      - VLLM_WORKER_MULTIPROC_METHOD=spawn
      - PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True,max_split_size_mb:512
      - NCCL_P2P_DISABLE=1
      - NCCL_CUMEM_ENABLE=0
      - VLLM_USE_FLASHINFER_SAMPLER=1
      - VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
      - VLLM_NO_USAGE_STATS=1
      - VLLM_FLOAT32_MATMUL_PRECISION=high
      - CUDA_DEVICE_MAX_CONNECTIONS=8
      - OMP_NUM_THREADS=1

    entrypoint: ["/bin/bash", "-c",
      "pip install xxhash -q && python3 -c \"import os, site; sp=site.getsitepackages()[0]; d='/vendor/genesis-vllm-patches-753'; [os.system(f'patch -p1 -N -d {sp} -i {os.path.join(d, f)}') for f in sorted(os.listdir(d)) if f.endswith('.patch')]\" && exec vllm serve \"$$@\"",
      "--"]

    command:
      - --model
      - /model
      - --host
      - 0.0.0.0
      - --port
      - "8000"
      - --served-model-name
      - qwen3.6-27b-autoround
      - --max-model-len
      - "65536"
      - --gpu-memory-utilization
      - "0.97"
      - --max-num-seqs
      - "1"
      - --max-num-batched-tokens
      - "4128"
      - --enable-chunked-prefill
      - --enable-prefix-caching
      - --reasoning-parser
      - qwen3
      - --tool-call-parser
      - qwen3_coder
      - --enable-auto-tool-choice
      - --kv-cache-dtype
      - fp8_e5m2
      - --compilation-config
      - '{"cudagraph_mode":"PIECEWISE"}'
      - --speculative-config
      - '{"method":"mtp","num_speculative_tokens":3}'
      - --quantization
      - auto_round
      - --dtype
      - float16
      - --tensor-parallel-size
      - "1"
      - --trust-remote-code
      - --no-scheduler-reserve-full-isl
```

### Model

Download `qwen3.6-27b-autoround-int4` from HuggingFace and place it at the mount path.

---

## Option B: llama.cpp + MTP (High Context + Vision)

**Best for:** 145k context + vision, tool compatibility, 50-60 tps

### Benchmarks

| Metric | Value |
|---|---|
| Mean TPS | 53.1 |
| Max TPS | 62.7 |
| Quality Score | 0.98 |
| Context Window | 145k tokens (+ vision) |

### Command

```bash
./llama-server \
  --model /models/qwen35/Unsloth_MTP_Qwen3.6-27B-IQ4_NL.gguf \
  --mmproj /models/qwen35/Unsloth_Qwen3.6-27B-mmproj-BF16.gguf \
  --spec-type draft-mtp \
  --spec-draft-n-max 2 \
  --spec-draft-p-min 0.75 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  -ctkd q8_0 \
  -ctvd q8_0 \
  --kv-unified \
  --n-gpu-layers auto \
  --split-mode none \
  --main-gpu 0 \
  --threads 6 \
  --ctx-size 148480 \
  --batch-size 2048 \
  --ubatch-size 512 \
  --no-mmap \
  --prio 3 \
  --reasoning-format deepseek \
  -n 8192 \
  -np 1 \
  --image-min-tokens 1024 \
  --flash-attn on \
  --jinja
```

### Models

- **Main model:** `Unsloth_MTP_Qwen3.6-27B-IQ4_NL.gguf`
- **Vision projector:** `Unsloth_Qwen3.6-27B-mmproj-BF16.gguf`

Both are MTP-compatible GGUF files from Unsloth.

---

## Comparison

| Feature | vLLM + PIECEWISE | llama.cpp + MTP |
|---|---|---|
| Speed | 70-80 tps | 50-60 tps |
| Context Window | 65k | 145k+ |
| Vision | ❌ | ✅ |
| Tool Calls | ✅ (qwen3_coder parser) | ✅ |
| VRAM Usage | ~22GB | ~20GB |
| Best For | Speed, API serving | Long context, vision, IDE integration |

---

## Troubleshooting

### GPU settings not applying

- Make sure you're running as root or with sudo
- Docker must be installed and running
- NVIDIA Container Toolkit must be configured: `apt install nvidia-container-toolkit`

### Out of memory

- Reduce `--ctx-size` in llama.cpp
- Reduce `--max-model-len` in vLLM
- Lower `--gpu-memory-utilization` from 0.97 to 0.90

### Low throughput

- Run the GPU setup script first
- Make sure `nvidia-smi` shows the power limit is set to 250W
- Check for other processes using GPU memory
