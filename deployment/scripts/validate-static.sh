#!/usr/bin/env bash
# Static repository checks. Does not pull images, start containers, change firewall or install units.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT}"

FAILED=0

check() {
  local name="$1"; shift
  if "$@"; then
    echo "OK   ${name}"
  else
    echo "FAIL ${name}"
    FAILED=1
  fi
}

for script in deployment/scripts/*.sh deployment/network/*.sh; do
  check "bash syntax: ${script}" bash -n "${script}"
done

check "Compose syntax" docker compose -f deployment/compose.yaml config --quiet

check "No obsolete LLM env variables" bash -c "! grep -R -nE 'LLM_API_KEY|LLM_MODEL|LLM_BASE_URL' deployment docs/Состояние.md docs/Архитектура.md README.md"
check "No direct detached startup in canonical docs/scripts" bash -c "! grep -R -nE 'docker compose( -f [^ ]+)? up -d' deployment README.md docs/Состояние.md docs/02-deployment-design/first-test-design.md"
check "No Docker auto-restart policy" bash -c "! grep -nE 'restart:[[:space:]]*(unless-stopped|always|on-failure)' deployment/compose.yaml"
check "No Docker socket mount" bash -c "! grep -R -n '/var/run/docker.sock' deployment/compose.yaml"
check "Only test workspace mounted" grep -q '/srv/openhands-agent/test-workspace:/projects' deployment/compose.yaml
check "Systemd owns foreground Compose" grep -q 'compose.yaml up --remove-orphans' deployment/systemd/openhands-agent.service
check "Firewall chains declared" bash -c "grep -q 'OPENHANDS-EGRESS' deployment/network/apply-egress-rules.sh && grep -q 'OPENHANDS-INPUT' deployment/network/apply-egress-rules.sh"

exit "${FAILED}"
