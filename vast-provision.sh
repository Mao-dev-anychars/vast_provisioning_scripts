#!/bin/bash
# Provisioning script for Vast.ai + ai-dock Stable Diffusion WebUI Forge (single GPU).
#
# Usage in Vast template (Environment Variables):
#   PROVISIONING_SCRIPT=https://raw.githubusercontent.com/kravtandr/my_sd_forge/main/deploy/vast-provision.sh
#   AUTO_UPDATE=false
#   FORGE_ARGS=--api --listen --xformers
#
# Multi-GPU + nginx load balancer: use vast-provision-multigpu.sh instead.
#
# Optional secrets (Account settings on Vast, NOT in public templates):
#   HF_TOKEN, CIVITAI_TOKEN, GITHUB_TOKEN
#
# Optional overrides:
#   MY_FORGE_REPO, MY_FORGE_REF
#   CHECKPOINT_MODEL_URL=https://civitai.com/api/download/models/82599
#   CHECKPOINT_MODEL_URLS=    # несколько URL через пробел/запятую

set -euo pipefail

MY_FORGE_REF="${MY_FORGE_REF:-main}"

if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

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
  printf "ERROR: cannot download lib/forge-provision-common.sh from %s\n" "$DEPLOY_RAW_URL" >&2
  exit 1
fi
# shellcheck source=lib/forge-provision-common.sh
source "$COMMON_LIB"

### ─── Configuration ─────────────────────────────────────────────────────────

DISK_GB_REQUIRED=30

MY_FORGE_REPO="${MY_FORGE_REPO:-https://github.com/kravtandr/my_sd_forge.git}"
FORGE_DIR="/opt/stable-diffusion-webui-forge"

APT_PACKAGES=()

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

function provisioning_print_end_single() {
  printf "\nProvisioning complete. Forge will start via supervisor (single instance).\n"
  printf "API: set FORGE_ARGS=--api --listen in your Vast template.\n"
  printf "Multi-GPU: use deploy/vast-provision-multigpu.sh\n\n"
}

function provisioning_start_single() {
  provisioning_run_shared_setup
  provisioning_print_end_single
}

provisioning_start_single
