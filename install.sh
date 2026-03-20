#!/usr/bin/env bash

set -euo pipefail

SELF_PATH="${BASH_SOURCE[0]}"

log() {
  printf '[wireguard-install] %s\n' "$*"
}

die() {
  printf '[wireguard-install] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash install.sh --server-url <public-ip-or-domain> [options]

Options:
  --server-url <value>        Required. Public IP or domain of the VPS.
  --server-port <value>       WireGuard UDP port. Default: 51820
  --peers <value>             Comma-separated device names. Default: phone
  --peer-dns <value>          DNS for clients. Default: 1.1.1.1
  --internal-subnet <value>   Internal VPN subnet. Default: 10.13.13.0
  --allowed-ips <value>       Client routes. Default: 0.0.0.0/0
  --tz <value>                Timezone. Default: detected system timezone or UTC
  --log-confs <value>         true or false. Default: true
  --puid <value>              Container PUID. Default: 0
  --pgid <value>              Container PGID. Default: 0
  --with-panel                Install the web panel as a systemd service.
  --panel-port <value>        Web panel TCP port. Default: 51821
  --panel-password <value>    Admin password for the web panel.
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

validate_peers() {
  local peers_csv="$1"
  local peer

  IFS=',' read -r -a peer_list <<<"${peers_csv}"
  [[ "${#peer_list[@]}" -gt 0 ]] || die "At least one peer must be provided."

  for peer in "${peer_list[@]}"; do
    [[ "${peer}" =~ ^[A-Za-z0-9]+$ ]] || die "Invalid peer name '${peer}'. Use only letters and numbers."
  done
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

ensure_python_for_panel() {
  if command -v python3 >/dev/null 2>&1; then
    local probe_dir
    probe_dir="$(mktemp -d)"
    if python3 -m venv "${probe_dir}/venv" >/dev/null 2>&1; then
      rm -rf "${probe_dir}"
      return
    fi
    rm -rf "${probe_dir}"
  fi

  load_os_release
  case "${ID}" in
    ubuntu|debian)
      log "Installing Python venv support for the web panel."
      apt-get update
      apt-get install -y python3 python3-venv
      ;;
    *)
      die "Python 3 with venv support is required for the web panel."
      ;;
  esac
}

ensure_host_networking() {
  local sysctl_path="/etc/sysctl.d/99-wireguard-vps.conf"

  log "Enabling IPv4 forwarding on the host."
  cat >"${sysctl_path}" <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null
}

generate_random_password() {
  python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(22)))
PY
}

generate_secret_key() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

generate_password_hash() {
  local raw_password="$1"
  PANEL_PASSWORD_RAW="${raw_password}" python3 - <<'PY'
import hashlib
import os
import secrets

password = os.environ["PANEL_PASSWORD_RAW"].encode("utf-8")
iterations = 390000
salt = secrets.token_bytes(16)
digest = hashlib.pbkdf2_hmac("sha256", password, salt, iterations).hex()
print(f"pbkdf2_sha256${iterations}${salt.hex()}${digest}")
PY
}

read_env_value() {
  local file_path="$1"
  local key="$2"

  [[ -f "${file_path}" ]] || return 0
  awk -F= -v wanted="${key}" '$1 == wanted { sub(/^[^=]+=*/, "", $0); print $0; exit }' "${file_path}"
}

write_panel_env_file() {
  local panel_env_path="${SCRIPT_DIR}/.panel.env"

  cat >"${panel_env_path}" <<EOF
WG_PANEL_HOST=0.0.0.0
WG_PANEL_PORT=${PANEL_PORT}
WG_PANEL_URL=http://${SERVER_URL}:${PANEL_PORT}
WG_PANEL_SECRET_KEY=${PANEL_SECRET_KEY}
WG_PANEL_PASSWORD_HASH=${PANEL_PASSWORD_HASH}
WG_PANEL_COOKIE_SECURE=false
EOF

  chmod 600 "${panel_env_path}"
}

install_panel_service() {
  local service_path="/etc/systemd/system/wireguard-panel.service"

  cat >"${service_path}" <<EOF
[Unit]
Description=WireGuard Web Panel
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=${SCRIPT_DIR}/.panel.env
ExecStart=${SCRIPT_DIR}/.panel-venv/bin/gunicorn --workers 2 --bind 0.0.0.0:\${WG_PANEL_PORT} panel.app:create_app()
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now wireguard-panel
}

install_web_panel() {
  local panel_env_path="${SCRIPT_DIR}/.panel.env"
  local panel_venv_path="${SCRIPT_DIR}/.panel-venv"
  local existing_hash=""
  local existing_secret=""

  ensure_python_for_panel

  log "Preparing the web panel virtual environment."
  python3 -m venv "${panel_venv_path}"
  "${panel_venv_path}/bin/pip" install --upgrade pip >/dev/null
  "${panel_venv_path}/bin/pip" install -r "${SCRIPT_DIR}/panel/requirements.txt"

  if [[ -f "${panel_env_path}" ]]; then
    existing_hash="$(read_env_value "${panel_env_path}" "WG_PANEL_PASSWORD_HASH")"
    existing_secret="$(read_env_value "${panel_env_path}" "WG_PANEL_SECRET_KEY")"
  fi

  PANEL_SECRET_KEY="${existing_secret:-$(generate_secret_key)}"

  if [[ -n "${PANEL_PASSWORD}" ]]; then
    PANEL_PASSWORD_HASH="$(generate_password_hash "${PANEL_PASSWORD}")"
    PANEL_PASSWORD_OUTPUT="${PANEL_PASSWORD}"
  elif [[ -n "${existing_hash}" ]]; then
    PANEL_PASSWORD_HASH="${existing_hash}"
    PANEL_PASSWORD_OUTPUT=""
  else
    PANEL_PASSWORD_OUTPUT="$(generate_random_password)"
    PANEL_PASSWORD_HASH="$(generate_password_hash "${PANEL_PASSWORD_OUTPUT}")"
  fi

  write_panel_env_file
  install_panel_service
  maybe_open_ufw_port "${PANEL_PORT}" tcp
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

write_env_file() {
  local env_path="${SCRIPT_DIR}/.env"

  if [[ -f "${env_path}" ]]; then
    local backup_path
    backup_path="${env_path}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${env_path}" "${backup_path}"
    log "Backed up existing .env to ${backup_path}."
  fi

  cat >"${env_path}" <<EOF
PUID=${PUID_VALUE}
PGID=${PGID_VALUE}
TZ=${TZ_VALUE}
SERVERURL=${SERVER_URL}
SERVERPORT=${SERVER_PORT}
PEERS=${PEERS}
PEERDNS=${PEER_DNS}
INTERNAL_SUBNET=${INTERNAL_SUBNET}
ALLOWEDIPS=${ALLOWED_IPS}
LOG_CONFS=${LOG_CONFS}
EOF
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

show_first_peer_hint() {
  local first_peer
  IFS=',' read -r first_peer _ <<<"${PEERS}"

  log "WireGuard is up."
  log "Peer config: ${SCRIPT_DIR}/config/peer_${first_peer}/peer_${first_peer}.conf"
  log "Show QR: bash ${SCRIPT_DIR}/show-peer.sh ${first_peer}"

  if [[ "${INSTALL_PANEL}" == "true" ]]; then
    log "Panel: http://${SERVER_URL}:${PANEL_PORT}"
    if [[ -n "${PANEL_PASSWORD_OUTPUT}" ]]; then
      log "Panel password: ${PANEL_PASSWORD_OUTPUT}"
    else
      log "Panel password: unchanged"
    fi
  fi
}

ensure_root "$@"

SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF_PATH}")" && pwd)"
SERVER_URL=""
SERVER_PORT="51820"
PEERS="phone"
PEER_DNS="1.1.1.1"
INTERNAL_SUBNET="10.13.13.0"
ALLOWED_IPS="0.0.0.0/0"
TZ_VALUE="$(detect_timezone)"
LOG_CONFS="true"
INSTALL_DOCKER="false"
PUID_VALUE="0"
PGID_VALUE="0"
INSTALL_PANEL="false"
PANEL_PORT="51821"
PANEL_PASSWORD=""
PANEL_PASSWORD_HASH=""
PANEL_PASSWORD_OUTPUT=""
PANEL_SECRET_KEY=""
COMPOSE_CMD=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --server-url)
      SERVER_URL="${2:-}"
      shift 2
      ;;
    --server-port)
      SERVER_PORT="${2:-}"
      shift 2
      ;;
    --peers)
      PEERS="${2:-}"
      shift 2
      ;;
    --peer-dns)
      PEER_DNS="${2:-}"
      shift 2
      ;;
    --internal-subnet)
      INTERNAL_SUBNET="${2:-}"
      shift 2
      ;;
    --allowed-ips)
      ALLOWED_IPS="${2:-}"
      shift 2
      ;;
    --tz)
      TZ_VALUE="${2:-}"
      shift 2
      ;;
    --log-confs)
      LOG_CONFS="${2:-}"
      shift 2
      ;;
    --puid)
      PUID_VALUE="${2:-}"
      shift 2
      ;;
    --pgid)
      PGID_VALUE="${2:-}"
      shift 2
      ;;
    --with-panel)
      INSTALL_PANEL="true"
      shift
      ;;
    --panel-port)
      PANEL_PORT="${2:-}"
      shift 2
      ;;
    --panel-password)
      PANEL_PASSWORD="${2:-}"
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

[[ -n "${SERVER_URL}" ]] || die "--server-url is required."
validate_peers "${PEERS}"
ensure_docker_and_compose
ensure_host_networking

mkdir -p "${SCRIPT_DIR}/config"
write_env_file

log "Pulling the WireGuard image."
"${COMPOSE_CMD[@]}" pull

log "Starting the WireGuard container."
"${COMPOSE_CMD[@]}" up -d

maybe_open_ufw_port "${SERVER_PORT}" udp

if [[ "${INSTALL_PANEL}" == "true" ]]; then
  install_web_panel
fi

show_first_peer_hint
