#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: bash show-peer.sh <peer-name>\n' >&2
  exit 1
fi

PEER_NAME="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PEER_CONF="${SCRIPT_DIR}/config/peer_${PEER_NAME}/peer_${PEER_NAME}.conf"

if [[ ! -f "${PEER_CONF}" ]]; then
  printf 'Peer config not found: %s\n' "${PEER_CONF}" >&2
  exit 1
fi

printf 'Config file: %s\n' "${PEER_CONF}"
docker exec -it wireguard /app/show-peer "${PEER_NAME}"
