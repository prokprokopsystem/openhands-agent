#!/bin/bash
# OpenHands Agent Canvas — остановка
set -e

COMPOSE_DIR="/srv/openhands-agent"
cd "$COMPOSE_DIR"

echo "=== OpenHands Agent Canvas — остановка ==="
docker compose down
echo "Контейнер остановлен. Состояние сохранено в config/ и workspace/."
