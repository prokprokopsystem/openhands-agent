#!/usr/bin/env bash
# Prepare OpenHands runtime directories. Does not start containers.
set -Eeuo pipefail

BASE="/srv/openhands-agent"
OWNER="igor:igor"

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

install -d -o igor -g igor -m 700 "${BASE}/config"
install -d -o igor -g igor -m 700 "${BASE}/test-workspace"
install -d -o igor -g igor -m 700 "${BASE}/secrets"
install -d -o igor -g igor -m 700 "${BASE}/logs"

if [[ -f "${BASE}/secrets/.env" ]]; then
  chown "${OWNER}" "${BASE}/secrets/.env"
  chmod 600 "${BASE}/secrets/.env"
fi

for dir in config test-workspace secrets logs; do
  mode=$(stat -c '%a' "${BASE}/${dir}")
  [[ "${mode}" == "700" ]] || { echo "ERROR: ${dir} mode=${mode}, expected 700" >&2; exit 1; }
done

echo "OpenHands runtime directories prepared with private permissions."
