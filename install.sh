#!/usr/bin/env bash

set -euo pipefail

SELF_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SELF_PATH}")" && pwd)"

log() {
  printf '[openvpn-install] %s\n' "$*"
}

die() {
  printf '[openvpn-install] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash install.sh --host <public-ip-or-domain> [options]

Options:
  --host <value>           Required. Public IP or domain clients should use.
  --client <value>         Initial client name. Default: phone
  --port <value>           OpenVPN UDP port. Default: 1194
  --dns <value>            Comma-separated DNS servers. Default: 1.1.1.1,1.0.0.1
  --subnet <value>         VPN subnet in CIDR. Default: 10.8.0.0/24
  --mtu <value>            OpenVPN mssfix value. Default: 1360
  --help                   Show this help.
EOF
}

ensure_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "${SELF_PATH}" "$@"
  fi

  die "Run this script as root or install sudo."
}

ensure_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y openvpn easy-rsa iptables openssl
}

detect_default_interface() {
  ip route show default | awk '/default/ {print $5; exit}'
}

ensure_sysctls() {
  cat >/etc/sysctl.d/99-openvpn.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl --load /etc/sysctl.d/99-openvpn.conf >/dev/null
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

stop_old_vpn_stacks() {
  if command -v docker >/dev/null 2>&1; then
    docker rm -f wg-easy wireguard >/dev/null 2>&1 || true
  fi

  systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true
  systemctl disable --now wireguard-panel >/dev/null 2>&1 || true
}

setup_easy_rsa_tree() {
  if [[ ! -d /etc/openvpn/easy-rsa ]]; then
    install -d -m 700 /etc/openvpn/easy-rsa
    cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
  fi
}

init_pki_if_needed() {
  cd /etc/openvpn/easy-rsa

  if [[ ! -d pki ]]; then
    ./easyrsa --batch init-pki
  fi

  if [[ ! -f pki/ca.crt ]]; then
    EASYRSA_REQ_CN="OpenVPN-CA" ./easyrsa --batch build-ca nopass
  fi

  if [[ ! -f pki/issued/server.crt ]]; then
    EASYRSA_REQ_CN="server" ./easyrsa --batch build-server-full server nopass
  fi

  if [[ ! -f pki/dh.pem ]]; then
    ./easyrsa --batch gen-dh
  fi

  if [[ ! -f /etc/openvpn/server/tls-crypt.key ]]; then
    install -d -m 700 /etc/openvpn/server
    openvpn --genkey --secret /etc/openvpn/server/tls-crypt.key
  fi

  ./easyrsa --batch gen-crl
}

build_client_if_needed() {
  cd /etc/openvpn/easy-rsa

  if [[ ! -f "pki/issued/${CLIENT_NAME}.crt" ]]; then
    EASYRSA_REQ_CN="${CLIENT_NAME}" ./easyrsa --batch build-client-full "${CLIENT_NAME}" nopass
  fi
}

copy_server_materials() {
  install -d -m 700 /etc/openvpn/server
  cp /etc/openvpn/easy-rsa/pki/ca.crt /etc/openvpn/server/ca.crt
  cp /etc/openvpn/easy-rsa/pki/issued/server.crt /etc/openvpn/server/server.crt
  cp /etc/openvpn/easy-rsa/pki/private/server.key /etc/openvpn/server/server.key
  cp /etc/openvpn/easy-rsa/pki/dh.pem /etc/openvpn/server/dh.pem
  cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
  chmod 600 /etc/openvpn/server/server.key /etc/openvpn/server/tls-crypt.key /etc/openvpn/server/crl.pem
}

subnet_network() {
  VPN_SUBNET_VALUE="${VPN_SUBNET}" python3 - <<'PY'
import ipaddress
import os

net = ipaddress.ip_network(os.environ["VPN_SUBNET_VALUE"], strict=False)
print(str(net.network_address))
PY
}

subnet_netmask() {
  VPN_SUBNET_VALUE="${VPN_SUBNET}" python3 - <<'PY'
import ipaddress
import os

net = ipaddress.ip_network(os.environ["VPN_SUBNET_VALUE"], strict=False)
print(str(net.netmask))
PY
}

write_firewall_scripts() {
  cat >/etc/openvpn/server/openvpn-up.sh <<EOF
#!/usr/bin/env bash
iptables -A FORWARD -i tun0 -j ACCEPT
iptables -A FORWARD -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -A POSTROUTING -s ${VPN_SUBNET} -o ${SERVER_INTERFACE} -j MASQUERADE
iptables -t mangle -A FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSSFIX}
iptables -t mangle -A FORWARD -o tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSSFIX}
EOF

  cat >/etc/openvpn/server/openvpn-down.sh <<EOF
#!/usr/bin/env bash
iptables -D FORWARD -i tun0 -j ACCEPT
iptables -D FORWARD -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -D POSTROUTING -s ${VPN_SUBNET} -o ${SERVER_INTERFACE} -j MASQUERADE
iptables -t mangle -D FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSSFIX}
iptables -t mangle -D FORWARD -o tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSSFIX}
EOF

  chmod 700 /etc/openvpn/server/openvpn-up.sh /etc/openvpn/server/openvpn-down.sh
}

write_server_config() {
  local network netmask dns_push
  network="$(subnet_network)"
  netmask="$(subnet_netmask)"

  dns_push=""
  IFS=',' read -r -a DNS_ARRAY <<<"${DNS_SERVERS}"
  for dns in "${DNS_ARRAY[@]}"; do
    dns_push="${dns_push}push \"dhcp-option DNS ${dns}\"\n"
  done

  cat >/etc/openvpn/server/server.conf <<EOF
port ${OVPN_PORT}
proto udp
dev tun
topology subnet
server ${network} ${netmask}
push "redirect-gateway def1 bypass-dhcp"
${dns_push}keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
script-security 2
up /etc/openvpn/server/openvpn-up.sh
down /etc/openvpn/server/openvpn-down.sh
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh /etc/openvpn/server/dh.pem
tls-crypt /etc/openvpn/server/tls-crypt.key
crl-verify /etc/openvpn/server/crl.pem
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
verb 3
explicit-exit-notify 1
mssfix ${MSSFIX}
status /var/log/openvpn-status.log
EOF
}

extract_cert_body() {
  local file="$1"
  awk 'BEGIN{flag=0} /BEGIN CERTIFICATE/{flag=1} flag{print} /END CERTIFICATE/{flag=0}' "${file}"
}

write_client_config() {
  local client_dir client_cert client_key ca_cert tls_crypt
  client_dir="${SCRIPT_DIR}/openvpn-clients/${CLIENT_NAME}"
  install -d -m 700 "${client_dir}"

  client_cert="$(extract_cert_body "/etc/openvpn/easy-rsa/pki/issued/${CLIENT_NAME}.crt")"
  client_key="$(cat "/etc/openvpn/easy-rsa/pki/private/${CLIENT_NAME}.key")"
  ca_cert="$(cat /etc/openvpn/easy-rsa/pki/ca.crt)"
  tls_crypt="$(cat /etc/openvpn/server/tls-crypt.key)"

  cat >"${client_dir}/${CLIENT_NAME}.ovpn" <<EOF
client
dev tun
proto udp
remote ${SERVER_HOST} ${OVPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-GCM
verb 3
auth-nocache
mssfix ${MSSFIX}

<ca>
${ca_cert}
</ca>
<cert>
${client_cert}
</cert>
<key>
${client_key}
</key>
<tls-crypt>
${tls_crypt}
</tls-crypt>
EOF
}

restart_openvpn() {
  systemctl enable --now openvpn-server@server
  systemctl restart openvpn-server@server
}

show_result() {
  log "OpenVPN server is up."
  log "Client profile: ${SCRIPT_DIR}/openvpn-clients/${CLIENT_NAME}/${CLIENT_NAME}.ovpn"
  log "Import that .ovpn file into OpenVPN Connect."
  log "Check server status with: systemctl status openvpn-server@server --no-pager"
}

ensure_root "$@"

SERVER_HOST=""
CLIENT_NAME="phone"
OVPN_PORT="1194"
DNS_SERVERS="1.1.1.1,1.0.0.1"
VPN_SUBNET="10.8.0.0/24"
MSSFIX="1360"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --host)
      SERVER_HOST="${2:-}"
      shift 2
      ;;
    --client)
      CLIENT_NAME="${2:-}"
      shift 2
      ;;
    --port)
      OVPN_PORT="${2:-}"
      shift 2
      ;;
    --dns)
      DNS_SERVERS="${2:-}"
      shift 2
      ;;
    --subnet)
      VPN_SUBNET="${2:-}"
      shift 2
      ;;
    --mtu)
      MSSFIX="${2:-}"
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

[[ -n "${SERVER_HOST}" ]] || die "--host is required."
SERVER_INTERFACE="$(detect_default_interface)"
[[ -n "${SERVER_INTERFACE}" ]] || die "Could not detect the default network interface."

stop_old_vpn_stacks
ensure_packages
ensure_sysctls
setup_easy_rsa_tree
init_pki_if_needed
build_client_if_needed
copy_server_materials
write_firewall_scripts
write_server_config
write_client_config
restart_openvpn
maybe_open_ufw_port "${OVPN_PORT}" udp
show_result
