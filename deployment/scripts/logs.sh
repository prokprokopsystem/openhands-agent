#!/bin/bash
# OpenHands Agent Canvas — логи
COMPOSE_DIR="/srv/openhands-agent"
cd "$COMPOSE_DIR"

echo "=== OpenHands Agent Canvas — логи (последние 100 строк) ==="
docker compose logs --tail 100 -f
