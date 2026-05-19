# Shared provisioning functions for Vast.ai + ai-dock Forge.
# Sourced by vast-provision.sh and vast-provision-multigpu.sh
#
# Checkpoint download (Vast template Environment Variables):
#   CHECKPOINT_MODEL_URL   — one URL (Civitai / HuggingFace)
#   CHECKPOINT_MODEL_URLS  — several URLs, через пробел или запятую (приоритет над CHECKPOINT_MODEL_URL)
#   CHECKPOINT_MODEL_URL=skip или none — не скачивать чекпоинт
#   Если не задано — default (anyloracleanlinearmix, Civitai 82599)

DEFAULT_CHECKPOINT_MODEL_URL="${DEFAULT_CHECKPOINT_MODEL_URL:-https://civitai.com/api/download/models/82599}"

function provisioning_init_checkpoint_models() {
  CHECKPOINT_MODELS=()

  if [[ -n "${CHECKPOINT_MODEL_URLS:-}" ]]; then
    local _urls="${CHECKPOINT_MODEL_URLS//,/ }"
    read -ra CHECKPOINT_MODELS <<< "$_urls"
    printf "Checkpoint URLs (CHECKPOINT_MODEL_URLS): %s\n" "${#CHECKPOINT_MODELS[@]}"
    return 0
  fi

  local url="${CHECKPOINT_MODEL_URL:-$DEFAULT_CHECKPOINT_MODEL_URL}"
  case "${url,,}" in
    skip|none|off|false|0|"")
      printf "Checkpoint download disabled (CHECKPOINT_MODEL_URL=%s).\n" "${CHECKPOINT_MODEL_URL:-}"
      return 0
      ;;
  esac

  CHECKPOINT_MODELS=("$url")
  printf "Checkpoint URL (CHECKPOINT_MODEL_URL): %s\n" "$url"
}

function provisioning_source_init() {
  if [[ ! -d /opt/environments/python ]]; then
    export MAMBA_BASE=true
  fi
  source /opt/ai-dock/etc/environment.sh
  source /opt/ai-dock/bin/venv-set.sh forge
}

function provisioning_sync_forge_repo() {
  local repo_url="$MY_FORGE_REPO"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    repo_url="${repo_url/https:\/\//https://${GITHUB_TOKEN}@}"
    printf "Using GITHUB_TOKEN for private repository access\n"
  fi

  printf "\n=== Syncing Forge fork: %s @ %s ===\n" "$MY_FORGE_REPO" "$MY_FORGE_REF"

  if [[ -d "${FORGE_DIR}/.git" ]]; then
    cd "${FORGE_DIR}"
    git remote set-url origin "$repo_url"
    if git fetch --depth 1 origin "$MY_FORGE_REF" 2>/dev/null && git checkout -f FETCH_HEAD && git clean -fd; then
      :
    else
      printf "WARNING: Could not sync %s (private repo? set GITHUB_TOKEN). Using existing Forge.\n" "$MY_FORGE_REPO"
    fi
  elif [[ -f "${FORGE_DIR}/launch.py" ]]; then
    printf "WARNING: Forge exists without git — skipping fork sync.\n"
  else
    rm -rf "${FORGE_DIR}"
    if ! git clone --depth 1 --branch "$MY_FORGE_REF" "$repo_url" "${FORGE_DIR}" 2>/dev/null; then
      rm -rf "${FORGE_DIR}"
      if ! git clone --depth 1 "$repo_url" "${FORGE_DIR}"; then
        printf "ERROR: Cannot clone %s — add GITHUB_TOKEN for private repos.\n" "$MY_FORGE_REPO" >&2
        return 1
      fi
      cd "${FORGE_DIR}"
      git fetch --depth 1 origin "$MY_FORGE_REF" || return 1
      git checkout -f "$MY_FORGE_REF" || return 1
    fi
  fi

  cd "${FORGE_DIR}"
  printf "Forge commit: %s\n" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf "Forge sync complete.\n\n"
}

function provisioning_warmup_forge() {
  local platform_args=""

  if [[ "${XPU_TARGET:-}" = "CPU" ]]; then
    platform_args="--use-cpu all --skip-torch-cuda-test --no-half"
  fi

  local provisioning_args="--skip-python-version-check --no-download-sd-model --do-not-download-clip --port 11404 --exit"
  local args_combined="${platform_args} $(cat /etc/forge_args.conf 2>/dev/null || true) ${provisioning_args}"

  printf "Running Forge warmup (first-time extension init)...\n"
  cd "${FORGE_DIR}"
  # shellcheck disable=SC1090
  source "${FORGE_VENV}/bin/activate"
  LD_PRELOAD=libtcmalloc.so python launch.py ${args_combined}
  deactivate
}

function pip_install() {
  "${FORGE_VENV_PIP}" install --no-cache-dir "$@"
}

function provisioning_get_apt_packages() {
  if [[ -n "${APT_PACKAGES[*]-}" && ${#APT_PACKAGES[@]} -gt 0 ]]; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
  fi
}

function provisioning_get_pip_packages() {
  if [[ -n "${PIP_PACKAGES[*]-}" && ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    pip_install "${PIP_PACKAGES[@]}"
  fi
}

function provisioning_get_extensions() {
  for repo in "${EXTENSIONS[@]}"; do
    [[ -z "$repo" ]] && continue
    local dir="${repo##*/}"
    local path="${FORGE_DIR}/extensions/${dir}"
    if [[ -d "$path" ]]; then
      if [[ "${AUTO_UPDATE,,}" == "true" ]]; then
        printf "Updating extension: %s...\n" "${repo}"
        (cd "$path" && git pull)
      fi
    else
      printf "Downloading extension: %s...\n" "${repo}"
      git clone "${repo}" "${path}" --recursive
    fi
  done
}

function provisioning_get_models() {
  if [[ -z "${2:-}" ]]; then
    return 0
  fi

  local dir="$1"
  shift
  mkdir -p "$dir"

  local -a arr
  if [[ $DISK_GB_ALLOCATED -ge $DISK_GB_REQUIRED ]]; then
    arr=("$@")
  else
    printf "WARNING: Disk %sGB < required %sGB — downloading only the first model.\n" \
      "$DISK_GB_ALLOCATED" "$DISK_GB_REQUIRED"
    arr=("$1")
  fi

  printf "Downloading %s file(s) to %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    [[ -z "$url" ]] && continue
    printf "Downloading: %s\n" "${url}"
    provisioning_download "${url}" "${dir}"
    printf "\n"
  done
}

function provisioning_print_header() {
  printf "\n##############################################\n"
  printf "#           Provisioning my_sd_forge         #\n"
  printf "#   Fork + models — please wait...           #\n"
  printf "##############################################\n\n"

  if [[ $DISK_GB_ALLOCATED -lt $DISK_GB_REQUIRED ]]; then
    printf "WARNING: Allocated disk %sGB < recommended %sGB\n\n" \
      "$DISK_GB_ALLOCATED" "$DISK_GB_REQUIRED"
  fi
}

function provisioning_download() {
  local url=$1
  local output_dir=$2
  local auth_token=""

  if [[ -n "${HF_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_token="${HF_TOKEN}"
  elif [[ -n "${CIVITAI_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
    auth_token="${CIVITAI_TOKEN}"
  fi

  local -a cmd=("curl" "-L" "-H" "Content-Type: application/json")
  if [[ -n $auth_token ]]; then
    cmd+=("-H" "Authorization: Bearer ${auth_token}")
  fi
  cmd+=("$url" "--create-dirs" "--output-dir" "$output_dir" "-O" "-J" "--progress-bar")

  local last_percentage=0
  local current_percentage=0
  local current_int=0

  "${cmd[@]}" 2>&1 |
    while IFS= read -d $'\r' -r p; do
      if [[ $p =~ ([0-9]+(\.[0-9]+)?)% ]]; then
        current_percentage=${BASH_REMATCH[1]}
        current_int=${current_percentage%.*}
        if [[ $current_int -lt 100 ]] && ((current_int >= last_percentage + 5)); then
          echo "  ${current_percentage}%"
          last_percentage=$current_int
        fi
      fi
    done
}

function provisioning_fetch_deploy_file() {
  local rel_path="$1"
  local dest="$2"
  local mode="${3:-644}"

  mkdir -p "$(dirname "$dest")"

  if [[ -n "${SCRIPT_DIR:-}" && -f "${SCRIPT_DIR}/${rel_path}" ]]; then
    install -m "$mode" "${SCRIPT_DIR}/${rel_path}" "$dest"
    return 0
  fi

  curl -fsSL "${DEPLOY_RAW_URL}/${rel_path}" -o "$dest"
  chmod "$mode" "$dest"
}

function provisioning_detect_gpu_count() {
  if [[ -n "${FORGE_GPU_COUNT:-}" ]]; then
    echo "$FORGE_GPU_COUNT"
    return
  fi
  if command -v nvidia-smi &>/dev/null; then
    nvidia-smi -L 2>/dev/null | wc -l
    return
  fi
  echo 1
}

function provisioning_disable_single_forge() {
  local forge_conf="/etc/supervisor/supervisord/conf.d/forge.conf"

  if [[ ! -f "$forge_conf" ]]; then
    return 0
  fi

  printf "Disabling single-instance forge supervisor program...\n"
  if supervisorctl status forge &>/dev/null; then
    supervisorctl stop forge || true
  fi

  if grep -q '^autostart=true' "$forge_conf"; then
    sudo sed -i 's/^autostart=true/autostart=false/' "$forge_conf"
  fi
}

function provisioning_install_forge_gpu_runner() {
  provisioning_fetch_deploy_file "bin/supervisor-forge-gpu.sh" "/opt/ai-dock/bin/supervisor-forge-gpu.sh" 755
}

function provisioning_write_forge_gpu_supervisor() {
  local gpu_count="$1"
  local user_name="${USER_NAME:-user}"
  local conf_dir="/etc/supervisor/supervisord/conf.d"

  sudo rm -f "${conf_dir}"/forge-gpu*.conf

  local i port
  for ((i = 0; i < gpu_count; i++)); do
    port=$((FORGE_BASE_PORT + i))
    sudo tee "${conf_dir}/forge-gpu${i}.conf" > /dev/null <<EOF
[program:forge-gpu${i}]
user=${user_name}
environment=PROC_NAME="forge-gpu${i}",USER=${user_name},HOME=/home/${user_name},CUDA_VISIBLE_DEVICES="${i}",FORGE_GPU_PORT="${port}"
command=/opt/ai-dock/bin/supervisor-forge-gpu.sh
process_name=forge-gpu${i}
numprocs=1
directory=/home/${user_name}
priority=$((1500 + i))
autostart=true
startsecs=30
startretries=5
autorestart=true
stopsignal=TERM
stopwaitsecs=30
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/supervisor/forge-gpu${i}.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=2
redirect_stderr=true
EOF
  done
}

function provisioning_write_nginx_upstream() {
  local gpu_count="$1"
  local upstream=""
  local i port

  for ((i = 0; i < gpu_count; i++)); do
    port=$((FORGE_BASE_PORT + i))
    upstream+="    server 127.0.0.1:${port} max_fails=3 fail_timeout=60s;"$'\n'
  done

  printf '%s' "$upstream"
}

function provisioning_setup_nginx_lb() {
  local gpu_count="$1"
  local upstream_servers
  upstream_servers="$(provisioning_write_nginx_upstream "$gpu_count")"

  printf "\n=== Configuring nginx load balancer on port %s ===\n" "$NGINX_LB_PORT"

  sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

  sudo tee /etc/nginx/sites-available/sd-forge-lb.conf > /dev/null <<EOF
# Auto-generated by vast-provision-multigpu.sh
upstream sd_forge_backend {
    least_conn;
${upstream_servers}    keepalive 32;
}

server {
    listen ${NGINX_LB_PORT};
    listen [::]:${NGINX_LB_PORT};
    server_name _;

    client_max_body_size 100m;

    location /nginx-health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    location / {
        proxy_pass http://sd_forge_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        proxy_read_timeout 600s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
    }
}
EOF

  sudo rm -f /etc/nginx/sites-enabled/default
  sudo ln -sf /etc/nginx/sites-available/sd-forge-lb.conf /etc/nginx/sites-enabled/sd-forge-lb.conf

  if ! grep -q "sites-enabled" /etc/nginx/nginx.conf 2>/dev/null; then
    sudo sed -i '/http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
  fi

  sudo nginx -t
}

function provisioning_write_nginx_supervisor() {
  local user_name="${USER_NAME:-user}"
  local conf="/etc/supervisor/supervisord/conf.d/nginx-sd-lb.conf"

  if [[ -f "$conf" ]]; then
    return 0
  fi

  sudo tee "$conf" > /dev/null <<EOF
[program:nginx-sd-lb]
user=root
command=/usr/sbin/nginx -g "daemon off;"
process_name=nginx-sd-lb
numprocs=1
priority=2500
autostart=true
startsecs=3
autorestart=true
stdout_logfile=/var/log/supervisor/nginx-sd-lb.log
redirect_stderr=true
EOF
}

function provisioning_reload_supervisor() {
  printf "Reloading supervisor...\n"
  sudo supervisorctl reread
  sudo supervisorctl update
}

function provisioning_run_shared_setup() {
  provisioning_source_init
  provisioning_init_checkpoint_models
  provisioning_sync_forge_repo

  DISK_GB_AVAILABLE=$(($(df --output=avail -m "${WORKSPACE}" | tail -n1) / 1000))
  DISK_GB_USED=$(($(df --output=used -m "${WORKSPACE}" | tail -n1) / 1000))
  DISK_GB_ALLOCATED=$(($DISK_GB_AVAILABLE + $DISK_GB_USED))

  provisioning_print_header
  provisioning_get_apt_packages
  provisioning_get_pip_packages
  provisioning_get_extensions
  provisioning_get_models "${CKPT_DIR}" "${CHECKPOINT_MODELS[@]}"
  provisioning_get_models "${LORA_DIR}" "${LORA_MODELS[@]}"
  provisioning_get_models "${CONTROLNET_DIR}" "${CONTROLNET_MODELS[@]}"
  provisioning_get_models "${VAE_DIR}" "${VAE_MODELS[@]}"
  provisioning_get_models "${ESRGAN_DIR}" "${ESRGAN_MODELS[@]}"
  provisioning_get_models "${CLIP_DIR}" "${CLIP_MODELS[@]}"
  provisioning_warmup_forge
}
