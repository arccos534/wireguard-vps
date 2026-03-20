#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
  printf 'Missing %s/.env\n' "${SCRIPT_DIR}" >&2
  exit 1
fi

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/.env"

printf 'wg-easy manages peers in the web UI.\n'
printf 'Open: http://%s:%s\n' "${WG_HOST}" "${UI_PORT}"
printf 'Create the client there and scan the QR from the browser.\n'
printf 'Login is disabled in the current temporary setup.\n'
