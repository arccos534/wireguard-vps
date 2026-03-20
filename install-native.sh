#!/usr/bin/env bash

set -euo pipefail

SELF_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF_PATH}")" && pwd)"

log() {
  printf '[wireguard-native] %s\n' "$*"
}

die() {
  printf '[wireguard-native] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash install-native.sh --host <public-ip-or-domain> [options]

Options:
  --host <value>         Required. Public IP or domain clients will use.
  --peer <value>         Client name. Default: phone
  --wg-port <value>      WireGuard UDP port. Default: 51820
  --dns <value>          Client DNS servers. Default: 1.1.1.1,1.0.0.1
  --subnet <value>       VPN subnet in CIDR. Default: 10.13.13.0/24
  --client-ip <value>    Client tunnel IP with mask. Default: 10.13.13.2/32
  --mtu <value>          Client/server MTU. Default: 1280
  --help                 Show this help.
EOF
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "${SELF_PATH}" "$@"
    fi
    die "Run this script as root or install sudo."
  fi
}

ensure_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y wireguard qrencode iptables
}

default_interface() {
  ip route show default | awk '/default/ {print $5; exit}'
}

default_server_ip() {
  VPN_SUBNET_VALUE="${VPN_SUBNET}" python3 - <<'PY'
import ipaddress
import os

subnet = ipaddress.ip_network(os.environ["VPN_SUBNET_VALUE"], strict=False)
print(f"{subnet.network_address + 1}/{subnet.prefixlen}")
PY
}

ensure_sysctls() {
  cat >/etc/sysctl.d/99-wireguard-native.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
EOF
  sysctl --load /etc/sysctl.d/99-wireguard-native.conf >/dev/null
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

  ufw allow "${port}/${protocol}" >/dev/null
}

stop_docker_vpn_stack() {
  if command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -qx 'wg-easy'; then
      log "Stopping the old wg-easy stack to free the port."
      (cd "${SCRIPT_DIR}" && docker compose down --remove-orphans >/dev/null 2>&1) || true
    fi
  fi
}

ensure_key_material() {
  install -d -m 700 /etc/wireguard/keys
  install -d -m 700 /etc/wireguard/clients

  if [[ ! -f /etc/wireguard/keys/server.key ]]; then
    umask 077
    wg genkey | tee /etc/wireguard/keys/server.key | wg pubkey >/etc/wireguard/keys/server.pub
  fi

  if [[ ! -f "/etc/wireguard/clients/${PEER_NAME}.key" ]]; then
    umask 077
    wg genkey | tee "/etc/wireguard/clients/${PEER_NAME}.key" | wg pubkey >"/etc/wireguard/clients/${PEER_NAME}.pub"
  fi

  if [[ ! -f "/etc/wireguard/clients/${PEER_NAME}.psk" ]]; then
    umask 077
    wg genpsk >"/etc/wireguard/clients/${PEER_NAME}.psk"
  fi
}

write_server_config() {
  local server_private server_public client_public client_psk server_ip
  server_private="$(tr -d '\n' </etc/wireguard/keys/server.key)"
  server_public="$(tr -d '\n' </etc/wireguard/keys/server.pub)"
  client_public="$(tr -d '\n' <"/etc/wireguard/clients/${PEER_NAME}.pub")"
  client_psk="$(tr -d '\n' <"/etc/wireguard/clients/${PEER_NAME}.psk")"
  server_ip="$(default_server_ip)"

  cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${server_ip}
ListenPort = ${WG_PORT}
PrivateKey = ${server_private}
MTU = ${WG_MTU}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WG_DEVICE} -j MASQUERADE
PostUp = iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WG_DEVICE} -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

[Peer]
# ${PEER_NAME}
PublicKey = ${client_public}
PresharedKey = ${client_psk}
AllowedIPs = ${CLIENT_IP}
PersistentKeepalive = 25
EOF

  chmod 600 /etc/wireguard/wg0.conf
}

write_client_config() {
  local server_public client_private client_psk output_dir
  server_public="$(tr -d '\n' </etc/wireguard/keys/server.pub)"
  client_private="$(tr -d '\n' <"/etc/wireguard/clients/${PEER_NAME}.key")"
  client_psk="$(tr -d '\n' <"/etc/wireguard/clients/${PEER_NAME}.psk")"
  output_dir="${SCRIPT_DIR}/native-clients/${PEER_NAME}"

  mkdir -p "${output_dir}"
  cat >"${output_dir}/${PEER_NAME}.conf" <<EOF
[Interface]
Address = ${CLIENT_IP}
PrivateKey = ${client_private}
DNS = ${WG_DNS}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${client_psk}
Endpoint = ${WG_HOST}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  qrencode -t ansiutf8 <"${output_dir}/${PEER_NAME}.conf" >"${output_dir}/${PEER_NAME}.qr.txt"
}

restart_wireguard() {
  systemctl enable --now wg-quick@wg0
  systemctl restart wg-quick@wg0
}

show_result() {
  log "Native WireGuard is up."
  log "Client config: ${SCRIPT_DIR}/native-clients/${PEER_NAME}/${PEER_NAME}.conf"
  log "QR (terminal text): ${SCRIPT_DIR}/native-clients/${PEER_NAME}/${PEER_NAME}.qr.txt"
  log "Check status with: wg show"
}

ensure_root "$@"

WG_HOST=""
PEER_NAME="phone"
WG_PORT="51820"
WG_DNS="1.1.1.1,1.0.0.1"
VPN_SUBNET="10.13.13.0/24"
CLIENT_IP="10.13.13.2/32"
WG_MTU="1280"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --host)
      WG_HOST="${2:-}"
      shift 2
      ;;
    --peer)
      PEER_NAME="${2:-}"
      shift 2
      ;;
    --wg-port)
      WG_PORT="${2:-}"
      shift 2
      ;;
    --dns)
      WG_DNS="${2:-}"
      shift 2
      ;;
    --subnet)
      VPN_SUBNET="${2:-}"
      shift 2
      ;;
    --client-ip)
      CLIENT_IP="${2:-}"
      shift 2
      ;;
    --mtu)
      WG_MTU="${2:-}"
      shift 2
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
WG_DEVICE="$(default_interface)"
[[ -n "${WG_DEVICE}" ]] || die "Could not detect the default network interface."

stop_docker_vpn_stack
ensure_packages
ensure_sysctls
ensure_key_material
write_server_config
write_client_config
restart_wireguard
maybe_open_ufw_port "${WG_PORT}" udp
show_result
