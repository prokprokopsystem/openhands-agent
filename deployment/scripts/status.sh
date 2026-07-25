#!/bin/bash
# OpenHands Agent Canvas — статус
set -e

COMPOSE_DIR="/srv/openhands-agent"
COMPOSE_FILE="${COMPOSE_DIR}/deployment/compose.yaml"
cd "${COMPOSE_DIR}"

echo "=== OpenHands Agent Canvas — статус ==="
echo ""

# Compose ps
docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || echo "Контейнер не запущен"

echo ""

# Health
echo "--- Health ---"
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -m 5 http://10.77.0.2:8000/canvas 2>/dev/null || echo "000")
echo "WebUI /canvas: HTTP ${HTTP_CODE}"

# Ресурсы контейнера
CONTAINER="openhands-agent"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "${CONTAINER}"; then
    echo ""
    echo "--- Ресурсы ---"
    docker stats --no-stream "${CONTAINER}" 2>/dev/null
    echo ""
    echo "--- Последние ошибки ---"
    docker logs --tail 20 "${CONTAINER}" 2>/dev/null | grep -iE "error|fatal|panic|fail" || echo "(нет)"
else
    echo "Контейнер не запущен."
fi

echo ""
echo "--- WireGuard ---"
ip addr show wg0 2>/dev/null | grep "inet " || echo "wg0 не найден"

echo ""
echo "--- Диск ---"
du -sh /srv/openhands-agent/*/ 2>/dev/null || true
