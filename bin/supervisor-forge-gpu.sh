#!/bin/bash
# One Forge process bound to a single GPU (CUDA_VISIBLE_DEVICES) and TCP port (FORGE_GPU_PORT).

set -euo pipefail

trap cleanup EXIT

function cleanup() {
  kill "$(jobs -p)" 2>/dev/null || true
  if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    deactivate 2>/dev/null || true
  fi
}

function start() {
  local port="${FORGE_GPU_PORT:?FORGE_GPU_PORT is required}"
  local gpu="${CUDA_VISIBLE_DEVICES:-0}"

  source /opt/ai-dock/etc/environment.sh
  source /opt/ai-dock/bin/venv-set.sh forge

  while [[ -f /run/workspace_sync || -f /run/container_config ]]; do
    sleep 1
  done

  fuser -k -SIGKILL "${port}"/tcp 2>/dev/null || true
  wait -n 2>/dev/null || true

  local platform_args=""
  if [[ "${XPU_TARGET:-}" = "CPU" ]]; then
    platform_args="--always-cpu --skip-torch-cuda-test --no-half"
  fi

  local args_combined="${platform_args} $(cat /etc/forge_args.conf 2>/dev/null || true)"

  printf "Starting Forge on GPU %s, port %s (PID $$)\n" "$gpu" "$port"

  cd /opt/stable-diffusion-webui-forge
  # shellcheck disable=SC1090
  source "${FORGE_VENV}/bin/activate"

  export CUDA_VISIBLE_DEVICES="${gpu}"
  LD_PRELOAD=libtcmalloc.so python launch.py \
    ${args_combined} \
    --port "${port}" \
    --device-id 0
}

start 2>&1
