#!/usr/bin/env bash
# =============================================================================
# Single RTX 3090 — GPU Undervolt, Overclock & Power Limit Setup
# =============================================================================
# Adapted from club-3090 discussion #152
# https://github.com/noonghunna/club-3090/discussions/152
#
# Original script by @ampersandru configured two GPUs (3090 + 5060 Ti).
# This version is for a single RTX 3090 only.
#
# What it does:
#   - Sets power limit to 250W
#   - Locks GPU core clocks to 1850MHz
#   - Applies +200MHz core overclock
#   - Applies +1000MHz memory overclock
#   - Enables persistence mode
#
# Run as root or with sudo on a machine with NVIDIA drivers installed.
# =============================================================================
set -euo pipefail

# 1. Enable persistence mode on the host
nvidia-smi -pm 1

# 2. Wait for Docker AND Internet connectivity
echo "Waiting for Docker daemon..."
while ! docker info > /dev/null 2>&1; do
  sleep 2
done

echo "Waiting for internet connectivity..."
while ! ping -c 1 -W 1 pypi.org > /dev/null 2>&1; do
  sleep 2
done

# 3. Write the Python script to a temporary file
cat << 'EOF' > /tmp/gpu_undervolt.py
from pynvml import *
from ctypes import byref

try:
    nvmlInit()

    # ==========================================
    # GPU 0: RTX 3090 (single GPU)
    # ==========================================
    try:
        dev_3090 = nvmlDeviceGetHandleByIndex(0)

        # 250W Limit & 1850MHz Lock (efficiency sweet spot for the 3090)
        nvmlDeviceSetPowerManagementLimit(dev_3090, 250000)
        nvmlDeviceSetGpuLockedClocks(dev_3090, 210, 1850)

        # Core Offset (+200MHz safe Ampere start)
        info_core_0 = c_nvmlClockOffset_t()
        info_core_0.version = nvmlClockOffset_v1
        info_core_0.type = NVML_CLOCK_GRAPHICS
        info_core_0.pstate = NVML_PSTATE_0
        info_core_0.clockOffsetMHz = 200
        nvmlDeviceSetClockOffsets(dev_3090, byref(info_core_0))

        # Memory Offset (+1000MHz performance consensus)
        info_mem_0 = c_nvmlClockOffset_t()
        info_mem_0.version = nvmlClockOffset_v1
        info_mem_0.type = NVML_CLOCK_MEM
        info_mem_0.pstate = NVML_PSTATE_0
        info_mem_0.clockOffsetMHz = 1000
        nvmlDeviceSetClockOffsets(dev_3090, byref(info_mem_0))

        print("[SUCCESS] RTX 3090 Configured (250W | 1850MHz | +200 Core | +1000 Mem)")
    except Exception as e:
        print(f"[FAIL] Could not configure GPU 0 (3090): {e}")

except Exception as e:
    print(f"Critical NVML initialization error: {e}")
finally:
    nvmlShutdown()
EOF

# 4. Execute via ephemeral Docker container
echo "Applying settings to GPU..."
docker run --rm \
  --privileged \
  --network host \
  --runtime=nvidia \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -v /tmp/gpu_undervolt.py:/tmp/gpu_undervolt.py \
  python:3.11-slim \
  bash -c "pip install nvidia-ml-py --quiet && python /tmp/gpu_undervolt.py"

# 5. Clean up
rm /tmp/gpu_undervolt.py

echo ""
echo "GPU configuration complete."
echo "Verify with: nvidia-smi -q | grep -E 'Power|Clock|Offset'"
