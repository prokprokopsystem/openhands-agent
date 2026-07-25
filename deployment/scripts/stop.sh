#!/bin/bash
# OpenHands Agent Canvas — остановка
# Состояние сохраняется в config/ и test-workspace/.
set -e

COMPOSE_FILE="/srv/openhands-agent/deployment/compose.yaml"
cd /srv/openhands-agent

echo "=== OpenHands Agent Canvas — остановка ==="
docker compose -f "${COMPOSE_FILE}" down

echo ""
echo "Контейнер остановлен."
echo "Состояние сохранено: /srv/openhands-agent/config/"
echo "Workspace сохранён: /srv/openhands-agent/test-workspace/"
