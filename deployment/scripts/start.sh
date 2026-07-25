#!/usr/bin/bash
# OpenHands Agent Canvas — запуск (удобная оболочка)
# Главный lifecycle: systemd (deployment/systemd/openhands-agent.service)
# Этот скрипт — для ручного тестового запуска.
set -euo pipefail

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"

echo "=== OpenHands Agent Canvas — запуск ==="

# Runtime-проверка
/usr/bin/bash "${BASE}/deployment/scripts/validate-runtime.sh"

echo ""
echo "--- docker compose config ---"
docker compose -f "${COMPOSE_FILE}" config 2>&1 | grep -v 'LOCAL_BACKEND_API_KEY' || true

echo ""
echo "Запуск..."
docker compose -f "${COMPOSE_FILE}" up -d

sleep 5
echo ""
docker compose -f "${COMPOSE_FILE}" ps

echo ""
echo 'Доступ: http://10.77.0.2:8000/canvas (только WireGuard)'
