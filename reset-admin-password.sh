#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: bash reset-admin-password.sh <new-password>\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

docker compose exec -T wg-easy cli db:admin:reset --password "$1"
