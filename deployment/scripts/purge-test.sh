#!/usr/bin/env bash
# Preview or destroy only the OpenHands test deployment.
set -Eeuo pipefail

BASE="/srv/openhands-agent"
UNIT_PATH="/etc/systemd/system/openhands-agent.service"
CONFIRM="${1:-}"

if [[ "${CONFIRM}" != "--confirm-destroy-test-data" ]]; then
  echo "PREVIEW ONLY"
  echo "Would stop/disable openhands-agent.service, remove OpenHands firewall rules,"
  echo "remove container/network, remove ${UNIT_PATH}, and delete ${BASE}."
  [[ -d "${BASE}" ]] && du -sh "${BASE}" || true
  exit 0
fi

sudo systemctl stop openhands-agent.service 2>/dev/null || true
sudo systemctl disable openhands-agent.service 2>/dev/null || true

if [[ -x "${BASE}/deployment/network/remove-egress-rules.sh" ]]; then
  sudo "${BASE}/deployment/network/remove-egress-rules.sh"
fi

if [[ -f "${BASE}/deployment/compose.yaml" ]]; then
  docker compose -f "${BASE}/deployment/compose.yaml" down --remove-orphans --volumes || true
fi

docker network rm openhands-net 2>/dev/null || true
sudo rm -f "${UNIT_PATH}"
sudo systemctl daemon-reload
sudo rm -rf --one-file-system "${BASE}"

echo "OpenHands test deployment destroyed."
