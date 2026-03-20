#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: bash show-client.sh <client-name>\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_PATH="${SCRIPT_DIR}/openvpn-clients/$1/$1.ovpn"

if [[ ! -f "${CLIENT_PATH}" ]]; then
  printf 'Client profile not found: %s\n' "${CLIENT_PATH}" >&2
  exit 1
fi

printf '%s\n' "${CLIENT_PATH}"
