#!/bin/bash
# Multi-GPU provisioning for Vast.ai: N× Forge (1 GPU each) + nginx least_conn on one port.
#
# Vast template (4× GPU instance):
#   PROVISIONING_SCRIPT=https://raw.githubusercontent.com/kravtandr/my_sd_forge/main/deploy/vast-provision-multigpu.sh
#   AUTO_UPDATE=false
#   FORGE_ARGS=--api --listen --xformers
#   FORGE_GPU_COUNT=4          # optional, auto-detected via nvidia-smi
#   NGINX_LB_PORT=7777         # single API port for llm_sd_api
#   FORGE_BASE_PORT=7860       # backends: 7860, 7861, ...
#   CHECKPOINT_MODEL_URL=https://civitai.com/api/download/models/82599
#   CHECKPOINT_MODEL_URLS=    # optional: несколько URL через пробел/запятую
#
# Expose in template Ports: 7777/tcp (and optionally 7860-7863 for direct UI per GPU).
#
# llm_sd_api config.py:
#   SDInstance("<vast-public-ip>", 7777)

set -euo pipefail

MY_FORGE_REF="${MY_FORGE_REF:-main}"

if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

# Тот же каталог, что и PROVISIONING_SCRIPT (например Mao-dev-anychars/vast_provisioning_scripts/.../main)
if [[ -n "${PROVISIONING_SCRIPT:-}" ]]; then
  DEPLOY_RAW_URL="${PROVISIONING_SCRIPT%/*}"
elif [[ -n "$SCRIPT_DIR" ]]; then
  DEPLOY_RAW_URL="$SCRIPT_DIR"
else
  DEPLOY_RAW_URL="https://raw.githubusercontent.com/kravtandr/my_sd_forge/${MY_FORGE_REF}/deploy"
fi

COMMON_LIB="/tmp/forge-provision-common.sh"
if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/lib/forge-provision-common.sh" ]]; then
  COMMON_LIB="${SCRIPT_DIR}/lib/forge-provision-common.sh"
elif curl -fsSL "${DEPLOY_RAW_URL}/lib/forge-provision-common.sh" -o "$COMMON_LIB"; then
  printf "Loaded common lib from %s\n" "$DEPLOY_RAW_URL"
else
  printf "ERROR: cannot download lib/forge-provision-common.sh from:\n  %s/lib/forge-provision-common.sh\n" "$DEPLOY_RAW_URL" >&2
  printf "Put deploy/lib/ and deploy/bin/ in the SAME repo/path as PROVISIONING_SCRIPT.\n" >&2
  exit 1
fi
# shellcheck source=lib/forge-provision-common.sh
source "$COMMON_LIB"

### ─── Configuration ─────────────────────────────────────────────────────────

DISK_GB_REQUIRED=30

MY_FORGE_REPO="${MY_FORGE_REPO:-https://github.com/kravtandr/my_sd_forge.git}"
FORGE_DIR="/opt/stable-diffusion-webui-forge"

# Load balancer (matches llm_sd_api SDInstance port)
NGINX_LB_PORT="${NGINX_LB_PORT:-7777}"
FORGE_BASE_PORT="${FORGE_BASE_PORT:-7860}"

APT_PACKAGES=(
  "nginx"
)

PIP_PACKAGES=(
  "onnxruntime-gpu"
  "onnx~=1.17.0"
  "tensorrt~=10.7.0"
  "tensorrt_cu12~=10.7.0"
  "tensorrt_cu12_bindings~=10.7.0"
  "tensorrt_cu12_libs~=10.7.0"
)

EXTENSIONS=()

LORA_MODELS=()
VAE_MODELS=()

ESRGAN_MODELS=(
  "https://huggingface.co/ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x4.pth"
  "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth"
  "https://huggingface.co/FacehugmanIII/4x_foolhardy_Remacri/resolve/main/4x_foolhardy_Remacri.pth"
)

CONTROLNET_MODELS=()
CLIP_MODELS=()

STORAGE_ROOT="${WORKSPACE}/storage/stable_diffusion/models"
CKPT_DIR="${STORAGE_ROOT}/ckpt"
LORA_DIR="${STORAGE_ROOT}/lora"
VAE_DIR="${STORAGE_ROOT}/vae"
ESRGAN_DIR="${STORAGE_ROOT}/esrgan"
CONTROLNET_DIR="${STORAGE_ROOT}/controlnet"
CLIP_DIR="${STORAGE_ROOT}/clip"

### ─── Multi-GPU setup ───────────────────────────────────────────────────────

function provisioning_setup_multigpu() {
  local gpu_count
  gpu_count="$(provisioning_detect_gpu_count)"
  gpu_count="${gpu_count// /}"

  if [[ ! "$gpu_count" =~ ^[0-9]+$ ]] || [[ "$gpu_count" -lt 1 ]]; then
    printf "ERROR: Invalid GPU count: '%s'\n" "$gpu_count" >&2
    exit 1
  fi

  printf "\n=== Multi-GPU mode: %s Forge instance(s) ===\n" "$gpu_count"
  printf "nginx least_conn -> 127.0.0.1:%s..%s\n" \
    "$FORGE_BASE_PORT" "$((FORGE_BASE_PORT + gpu_count - 1))"
  printf "Public API port: %s\n\n" "$NGINX_LB_PORT"

  provisioning_install_forge_gpu_runner
  provisioning_disable_single_forge
  provisioning_write_forge_gpu_supervisor "$gpu_count"
  provisioning_setup_nginx_lb "$gpu_count"
  provisioning_write_nginx_supervisor
  provisioning_reload_supervisor
}

function provisioning_print_end_multigpu() {
  local gpu_count
  gpu_count="$(provisioning_detect_gpu_count)"

  printf "\n##############################################\n"
  printf "#     Multi-GPU provisioning complete        #\n"
  printf "##############################################\n"
  printf "Forge backends : %s..%s (1 GPU each)\n" \
    "$FORGE_BASE_PORT" "$((FORGE_BASE_PORT + gpu_count - 1))"
  printf "Load balancer  : 0.0.0.0:%s (nginx least_conn)\n" "$NGINX_LB_PORT"
  printf "Health check   : http://127.0.0.1:%s/nginx-health\n" "$NGINX_LB_PORT"
  printf "SD API example : http://<instance-ip>:%s/sdapi/v1/txt2img\n" "$NGINX_LB_PORT"
  printf "\nSet FORGE_ARGS=--api --listen in the Vast template.\n"
  printf "Expose port %s/tcp in the template Ports section.\n\n" "$NGINX_LB_PORT"
}

function provisioning_start_multigpu() {
  provisioning_run_shared_setup
  provisioning_setup_multigpu
  provisioning_print_end_multigpu
}

provisioning_start_multigpu
