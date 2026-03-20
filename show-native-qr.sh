#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: bash show-native-qr.sh <peer-name>\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QR_PATH="${SCRIPT_DIR}/native-clients/$1/$1.qr.txt"

if [[ ! -f "${QR_PATH}" ]]; then
  printf 'QR file not found: %s\n' "${QR_PATH}" >&2
  exit 1
fi

cat "${QR_PATH}"
