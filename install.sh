#!/usr/bin/env bash

set -euo pipefail

SELF_PATH="${BASH_SOURCE[0]}"

log() {
  printf '[wg-easy-install] %s\n' "$*"
}

die() {
  printf '[wg-easy-install] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash install.sh --host <public-ip-or-domain> [options]

Options:
  --host <value>              Required. Public IP or domain clients will use.
  --wg-port <value>           WireGuard UDP port. Default: 443
  --ui-port <value>           Web UI TCP port. Default: 51821
  --wg-device <value>         Host network interface for NAT. Default: ens3
  --dns <value>               Client DNS servers. Default: 1.1.1.1,1.0.0.1
  --allowed-ips <value>       Allowed IPs for new clients. Default: 0.0.0.0/0
  --mtu <value>               Client MTU. Default: 1280
  --tz <value>                Timezone. Default: detected system timezone or UTC
  --install-docker            Install Docker on Ubuntu/Debian if missing.
  --help                      Show this help.
EOF
}

ensure_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$SELF_PATH" "$@"
  fi

  die "Run this script as root or install sudo."
}

detect_timezone() {
  if [[ -f /etc/timezone ]]; then
    tr -d '\n' </etc/timezone
    return
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    local tz
    tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
    if [[ -n "${tz}" ]]; then
      printf '%s' "${tz}"
      return
    fi
  fi

  printf 'UTC'
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "Cannot detect the operating system."
  # shellcheck disable=SC1091
  . /etc/os-release
}

install_docker_official() {
  load_os_release

  case "${ID}" in
    ubuntu)
      log "Installing Docker from Docker's official Ubuntu repository."
      apt-get update
      apt-get install -y ca-certificates curl
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    debian)
      log "Installing Docker from Docker's official Debian repository."
      apt-get update
      apt-get install -y ca-certificates curl
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    *)
      die "Automatic Docker installation is supported only on Ubuntu/Debian."
      ;;
  esac

  systemctl enable --now docker
}

ensure_docker_and_compose() {
  if ! command -v docker >/dev/null 2>&1; then
    if [[ "${INSTALL_DOCKER}" == "true" ]]; then
      install_docker_official
    else
      die "Docker is not installed. Re-run with --install-docker or install Docker first."
    fi
  fi

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return
  fi

  die "Docker Compose is not available. Install docker-compose-plugin or docker-compose."
}

ensure_host_networking() {
  local sysctl_path="/etc/sysctl.d/99-wg-easy.conf"

  log "Enabling host sysctls required by WireGuard."
  cat >"${sysctl_path}" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
EOF
  sysctl --load "${sysctl_path}" >/dev/null
}

maybe_open_ufw_port() {
  local port="$1"
  local protocol="$2"

  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi

  local ufw_status
  ufw_status="$(ufw status 2>/dev/null | head -n 1 || true)"
  if [[ "${ufw_status}" == *"inactive"* ]] || [[ -z "${ufw_status}" ]]; then
    return
  fi

  log "Opening ${port}/${protocol} in ufw."
  ufw allow "${port}/${protocol}" >/dev/null
}

stop_legacy_panel_service() {
  if systemctl list-unit-files | grep -q '^wireguard-panel\.service'; then
    log "Disabling the old custom wireguard-panel service."
    systemctl disable --now wireguard-panel >/dev/null 2>&1 || true
  fi
}

backup_legacy_data() {
  local timestamp
  timestamp="$(date +%Y%m%d%H%M%S)"

  if [[ -d "${SCRIPT_DIR}/data" ]]; then
    mv "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/data.backup.${timestamp}"
    log "Backed up previous wg-easy data directory."
  fi

  if [[ -d "${SCRIPT_DIR}/config" ]]; then
    mv "${SCRIPT_DIR}/config" "${SCRIPT_DIR}/config.backup.${timestamp}"
    log "Backed up legacy config directory."
  fi

  if [[ -f "${SCRIPT_DIR}/.panel.env" ]]; then
    mv "${SCRIPT_DIR}/.panel.env" "${SCRIPT_DIR}/.panel.env.backup.${timestamp}"
    log "Backed up legacy panel environment."
  fi

  if [[ -d "${SCRIPT_DIR}/.panel-venv" ]]; then
    mv "${SCRIPT_DIR}/.panel-venv" "${SCRIPT_DIR}/.panel-venv.backup.${timestamp}"
    log "Backed up legacy panel virtual environment."
  fi
}

write_env_file() {
  cat >"${SCRIPT_DIR}/.env" <<EOF
TZ=${TZ_VALUE}
WG_HOST=${WG_HOST}
WG_PORT=${WG_PORT}
UI_PORT=${UI_PORT}
WG_DEVICE=${WG_DEVICE}
WG_DNS=${WG_DNS}
WG_ALLOWED_IPS=${WG_ALLOWED_IPS}
WG_MTU=${WG_MTU}
EOF
}

wait_for_wg_easy() {
  local tries=0
  while (( tries < 30 )); do
    if docker inspect -f '{{.State.Status}}' wg-easy 2>/dev/null | grep -q '^running$'; then
      return
    fi
    sleep 2
    tries=$((tries + 1))
  done

  die "wg-easy did not reach running state in time."
}
show_hints() {
  log "wg-easy is up."
  log "Web UI: http://${WG_HOST}:${UI_PORT}"
  log "Login is disabled in this temporary setup."
  log "Create clients in the UI and scan the QR from there."
}

ensure_root "$@"

SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF_PATH}")" && pwd)"
WG_HOST=""
WG_PORT="443"
UI_PORT="51821"
WG_DEVICE="ens3"
WG_DNS="1.1.1.1,1.0.0.1"
WG_ALLOWED_IPS="0.0.0.0/0"
WG_MTU="1280"
TZ_VALUE="$(detect_timezone)"
INSTALL_DOCKER="false"
COMPOSE_CMD=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --host)
      WG_HOST="${2:-}"
      shift 2
      ;;
    --wg-port)
      WG_PORT="${2:-}"
      shift 2
      ;;
    --ui-port)
      UI_PORT="${2:-}"
      shift 2
      ;;
    --wg-device)
      WG_DEVICE="${2:-}"
      shift 2
      ;;
    --dns)
      WG_DNS="${2:-}"
      shift 2
      ;;
    --allowed-ips)
      WG_ALLOWED_IPS="${2:-}"
      shift 2
      ;;
    --mtu)
      WG_MTU="${2:-}"
      shift 2
      ;;
    --tz)
      TZ_VALUE="${2:-}"
      shift 2
      ;;
    --install-docker)
      INSTALL_DOCKER="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ -n "${WG_HOST}" ]] || die "--host is required."

ensure_docker_and_compose
ensure_host_networking
stop_legacy_panel_service
backup_legacy_data
mkdir -p "${SCRIPT_DIR}/data"
write_env_file

log "Pulling the wg-easy image."
"${COMPOSE_CMD[@]}" pull

log "Stopping any previous containers from this stack."
"${COMPOSE_CMD[@]}" down --remove-orphans >/dev/null 2>&1 || true

log "Starting wg-easy."
"${COMPOSE_CMD[@]}" up -d
wait_for_wg_easy

maybe_open_ufw_port "${WG_PORT}" udp
maybe_open_ufw_port "${UI_PORT}" tcp

show_hints
