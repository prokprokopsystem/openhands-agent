#!/bin/bash
# OpenHands Agent Canvas — статус
set -u

COMPOSE_DIR="/srv/openhands-agent"
cd "$COMPOSE_DIR" || exit 1

echo "=== OpenHands Agent Canvas — статус ==="
docker compose ps

echo ""
echo "=== Использование диска ==="
du -sh /srv/openhands-agent/config \
       /srv/openhands-agent/workspace \
       /srv/openhands-agent/logs 2>/dev/null || true

echo ""
echo "=== WebUI ==="
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout 5 \
  http://10.77.0.2:8000/canvas 2>/dev/null || true)"

if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
    echo "HTTP $HTTP_CODE — http://10.77.0.2:8000/canvas"
else
    echo "недоступен — http://10.77.0.2:8000/canvas"
fi
