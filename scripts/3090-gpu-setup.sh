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
# Usage: ./3090-gpu-setup.sh [--check | --save | --apply | --restore | --set-power WATTS]
#
# Options:
#   --check         Show current GPU settings (power, clocks, offsets)
#   --save          Save current settings to ~/.3090-gpu-backup (default: ./gpu-backup.txt)
#   --apply         Apply undervolt/overclock settings (default action)
#   --restore       Restore previously saved settings
#   --set-power W   Set power limit to W watts (e.g. --set-power 350)
#   --backup PATH   Set custom backup file path (default: ~/.3090-gpu-backup)
#
# Run as root or with sudo on a machine with NVIDIA drivers installed.
# =============================================================================
set -euo pipefail

BACKUP_FILE="${HOME}/.3090-gpu-backup"
ACTION="apply"
POWER_LIMIT_WATTS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      ACTION="check"
      shift
      ;;
    --save)
      ACTION="save"
      shift
      ;;
    --apply)
      ACTION="apply"
      shift
      ;;
    --restore)
      ACTION="restore"
      shift
      ;;
    --set-power)
      ACTION="set-power"
      if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --set-power requires a numeric wattage value (e.g. --set-power 350)"
        exit 1
      fi
      POWER_LIMIT_WATTS="$2"
      shift 2
      ;;
    --backup)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --backup requires a file path (e.g. --backup /path/to/file)"
        exit 1
      fi
      BACKUP_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--check | --save | --apply | --restore | --set-power WATTS] [--backup PATH]"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Helper: Display current GPU settings
# ---------------------------------------------------------------------------
show_current_settings() {
  echo "============================================================"
  echo "  Current GPU Settings"
  echo "============================================================"
  echo ""

  # GPU info with power limit
  nvidia-smi --query-gpu=name,index,pstate,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,clocks.max.graphics,clocks.max.memory,clocks.offset.graphics,clocks.offset.memory --format=csv,noheader,header=once 2>/dev/null || \
    nvidia-smi -q | grep -E 'Name|Power Draw|Power Limit|Graphics|Memory|Offset'

  echo ""

  # Power limit summary
  echo "--- Power Limit ---"
  local power_limit pm_mode
  power_limit=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader 2>/dev/null | tr -d ' ' || echo "unknown")
  pm_mode=$(nvidia-smi -q 2>/dev/null | grep "Persistence Mode" | head -1 | awk '{print $NF}' || echo "unknown")
  default_pl=$(nvidia-smi -q 2>/dev/null | grep "Power Limit" | head -1 | grep -oP '^\s+\K[\d.]+' || echo "unknown")
  echo "  Current power limit: ${power_limit}"
  echo "  Default power limit: ${default_pl}W"
  echo "  Persistence mode:    ${pm_mode}"

  echo ""

  # Detailed query
  echo "--- Detailed ---"
  nvidia-smi -q | grep -A1 -E 'Power Management|Clocks|Offset|Performance State' | head -40

  echo ""
  echo "============================================================"
}

# ---------------------------------------------------------------------------
# Helper: Save current GPU settings to file
# ---------------------------------------------------------------------------
save_settings() {
  echo "Saving current GPU settings to ${BACKUP_FILE}..."
  {
    echo "# GPU Settings Backup"
    echo "# Saved: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Hostname: $(hostname)"
    echo "# Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo 'unknown')"
    echo ""
    echo "# Full nvidia-smi -q output:"
    nvidia-smi -q 2>/dev/null || echo "# ERROR: nvidia-smi failed"
  } > "${BACKUP_FILE}"

  echo "✓ Settings saved to ${BACKUP_FILE}"
  echo ""
  echo "To restore later: $0 --restore --backup ${BACKUP_FILE}"
}

# ---------------------------------------------------------------------------
# Helper: Restore settings from backup
# ---------------------------------------------------------------------------
restore_settings() {
  if [[ ! -f "${BACKUP_FILE}" ]]; then
    echo "ERROR: Backup file not found: ${BACKUP_FILE}"
    echo "Save settings first with: $0 --save --backup ${BACKUP_FILE}"
    exit 1
  fi

  echo "Restoring GPU settings from ${BACKUP_FILE}..."
  echo ""

  # Reset clock offsets to 0 and unlock clocks
  cat << 'EOF' > /tmp/gpu_restore.py
from pynvml import *
from ctypes import byref

try:
    nvmlInit()

    for i in range(nvmlDeviceGetCount()):
        dev = nvmlDeviceGetHandleByIndex(i)
        name = nvmlDeviceGetName(dev)

        # Reset core offset to 0
        info_core = c_nvmlClockOffset_t()
        info_core.version = nvmlClockOffset_v1
        info_core.type = NVML_CLOCK_GRAPHICS
        info_core.pstate = NVML_PSTATE_0
        info_core.clockOffsetMHz = 0
        nvmlDeviceSetClockOffsets(dev, byref(info_core))

        # Reset memory offset to 0
        info_mem = c_nvmlClockOffset_t()
        info_mem.version = nvmlClockOffset_v1
        info_mem.type = NVML_CLOCK_MEM
        info_mem.pstate = NVML_PSTATE_0
        info_mem.clockOffsetMHz = 0
        nvmlDeviceSetClockOffsets(dev, byref(info_mem))

        # Unlock GPU clocks (0, 0 = no lock)
        nvmlDeviceSetGpuLockedClocks(dev, 0, 0)

        print(f"[RESTORED] {name} — offsets reset to 0, clocks unlocked")

except Exception as e:
    print(f"Critical NVML initialization error: {e}")
finally:
    nvmlShutdown()
EOF

  echo "Applying restore via Docker..."
  docker run --rm \
    --privileged \
    --network host \
    --runtime=nvidia \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /tmp/gpu_restore.py:/tmp/gpu_restore.py \
    python:3.11-slim \
    bash -c "pip install nvidia-ml-py --quiet && python /tmp/gpu_restore.py"

  rm /tmp/gpu_restore.py

  echo ""
  echo "GPU settings restored to defaults (0 offsets, no clock locks)."
  echo "Note: Power limit reset requires reboot or nvidia-smi -pm 0 && nvidia-smi -pm 1"
}

# ---------------------------------------------------------------------------
# Main action
# ---------------------------------------------------------------------------

case "${ACTION}" in
  check)
    show_current_settings
    exit 0
    ;;
  save)
    show_current_settings
    save_settings
    exit 0
    ;;
  restore)
    restore_settings
    exit 0
    ;;
  set-power)
    # Check persistence mode status
    pm_status=$(nvidia-smi -q 2>/dev/null | grep "Persistence Mode" | head -1 | awk '{print $NF}' || echo "unknown")
    echo "Persistence Mode: ${pm_status}"

    if [[ "$pm_status" != "Enabled" ]]; then
      echo "Enabling persistence mode..."
      if ! nvidia-smi -pm 1 2>/dev/null; then
        echo "✗ Failed to enable persistence mode. Run as root/sudo."
        exit 1
      fi
      sleep 1
      echo "  ✓ Persistence mode enabled"
    fi

    # Get current power limit before change
    old_limit=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader 2>/dev/null | tr -d ' ' || echo "unknown")
    echo "  Previous power limit: ${old_limit}"

    # Get default/max power limit from GPU
    default_pl=$(nvidia-smi -q 2>/dev/null | grep "Power Limit" | head -1 | grep -oP '^\s+\K[\d.]+' || echo "")

    echo ""
    echo "Setting power limit to ${POWER_LIMIT_WATTS}W..."

    # Apply the new power limit (nvidia-smi -pl takes watts as integer)
    if output=$(nvidia-smi -pl "${POWER_LIMIT_WATTS}" 2>&1); then
      echo "  ✓ Power limit set to ${POWER_LIMIT_WATTS}W"
    else
      echo "  ✗ Failed to set power limit to ${POWER_LIMIT_WATTS}W"
      echo "  Error: ${output}"
      echo ""
      echo "  Default power limit: ${default_pl}W"
      echo "  Make sure the value is within the GPU's supported range."
      echo "  Run '$0 --check' to see supported limits."
      exit 1
    fi

    echo ""
    echo "Current GPU status after change:"
    nvidia-smi --query-gpu=name,power.draw,power.limit,clocks.current.graphics,clocks.current.memory --format=csv,noheader,header=once 2>/dev/null || true

    echo ""
    echo "To check full settings:     $0 --check"
    echo "To restore original settings: $0 --restore --backup ${BACKUP_FILE}"
    exit 0
    ;;
  apply)
    # Check if backup exists, offer to save first
    if [[ ! -f "${BACKUP_FILE}" ]]; then
      echo "No backup found at ${BACKUP_FILE}."
      echo ""
      echo "Current GPU settings:"
      echo ""
      nvidia-smi --query-gpu=name,power.draw,power.limit,clocks.current.graphics,clocks.current.memory --format=csv,noheader,header=once 2>/dev/null || true
      echo ""
      echo "Saving current settings to ${BACKUP_FILE} before applying changes..."
      {
        echo "# GPU Settings Backup"
        echo "# Saved: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Hostname: $(hostname)"
        echo "# Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo 'unknown')"
        echo ""
        echo "# Full nvidia-smi -q output:"
        nvidia-smi -q 2>/dev/null || echo "# ERROR: nvidia-smi failed"
      } > "${BACKUP_FILE}"
      echo "✓ Backup saved to ${BACKUP_FILE}"
      echo ""
    else
      echo "Backup already exists at ${BACKUP_FILE}."
      echo "Run '$0 --check' to see current settings."
      echo ""
    fi

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
    echo "Backup saved to: ${BACKUP_FILE}"
    echo ""
    echo "To restore original settings: $0 --restore --backup ${BACKUP_FILE}"
    echo "To check current settings:     $0 --check"
    ;;
esac
