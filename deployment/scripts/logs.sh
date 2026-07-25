#!/usr/bin/bash
# OpenHands Agent Canvas — логи
COMPOSE_FILE="/srv/openhands-agent/deployment/compose.yaml"
cd /srv/openhands-agent

echo "=== OpenHands Agent Canvas — логи ==="
docker compose -f "${COMPOSE_FILE}" logs --tail 100 -f
