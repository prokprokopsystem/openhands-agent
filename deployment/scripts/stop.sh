#!/usr/bin/env bash
# Stop OpenHands through systemd. Runtime data is preserved.
set -Eeuo pipefail

UNIT="openhands-agent.service"
systemctl cat "${UNIT}" >/dev/null 2>&1 || { echo "ERROR: ${UNIT} is not installed" >&2; exit 1; }

sudo systemctl stop "${UNIT}"
echo "OpenHands stopped. Firewall rules were removed by ExecStopPost."
echo "Preserved: /srv/openhands-agent/config and test-workspace"
