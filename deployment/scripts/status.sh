#!/bin/bash
# OpenHands Agent Canvas — статус
COMPOSE_DIR="/srv/openhands-agent"
cd "$COMPOSE_DIR"

echo "=== OpenHands Agent Canvas — статус ==="
docker compose ps
echo ""
echo "=== Использование диска ==="
du -sh /srv/openhands-agent/*
echo ""
echo "=== Health ==="
curl -s -o /dev/null -w "HTTP %{http_code}" http://10.77.0.2:8000/ 2>/dev/null || echo "недоступен"
echo ""
