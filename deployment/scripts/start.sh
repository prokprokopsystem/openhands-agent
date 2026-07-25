#!/usr/bin/env bash
# Start OpenHands through the systemd lifecycle owner.
set -Eeuo pipefail

BASE="/srv/openhands-agent"
ENV_FILE="${BASE}/secrets/.env"
UNIT="openhands-agent.service"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: ${ENV_FILE} missing" >&2; exit 1; }
[[ "$(stat -c '%a' "${ENV_FILE}")" == "600" ]] || { echo "ERROR: .env must be mode 600" >&2; exit 1; }

for dir in config test-workspace secrets logs; do
  [[ -d "${BASE}/${dir}" ]] || { echo "ERROR: ${BASE}/${dir} missing" >&2; exit 1; }
  [[ "$(stat -c '%a' "${BASE}/${dir}")" == "700" ]] || { echo "ERROR: ${dir} must be mode 700" >&2; exit 1; }
done

KEY=$(sed -n 's/^LOCAL_BACKEND_API_KEY=//p' "${ENV_FILE}" | tail -n 1)
[[ -n "${KEY}" ]] || { echo "ERROR: LOCAL_BACKEND_API_KEY is empty" >&2; exit 1; }
if [[ "${KEY}" == "your-generated-key-here" || "${KEY}" == "***" || "${KEY}" == *"<"* || "${KEY}" == *">"* ]]; then
  echo "ERROR: LOCAL_BACKEND_API_KEY is still a template" >&2
  exit 1
fi

ip -4 addr show dev wg0 | grep -q '10.77.0.2/' || { echo "ERROR: WireGuard address 10.77.0.2 is absent" >&2; exit 1; }
systemctl cat "${UNIT}" >/dev/null 2>&1 || { echo "ERROR: ${UNIT} is not installed" >&2; exit 1; }

sudo systemctl start "${UNIT}"
sudo systemctl --no-pager --full status "${UNIT}"
echo "WebUI: http://10.77.0.2:8000/canvas (WireGuard only)"
