#!/bin/bash
# OpenHands Agent Canvas — полное удаление тестового запуска
# БЕЗ --confirm-destroy-test-data показывает только что будет удалено.
# С --confirm-destroy-test-data выполняет удаление.

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"

echo "=== OpenHands Agent Canvas — purge ==="
echo ""

if [ "$1" != "--confirm-destroy-test-data" ]; then
    echo "⚠️  РЕЖИМ ПРОСМОТРА. Для удаления: $0 --confirm-destroy-test-data"
    echo ""
    echo "Будет удалено:"
    echo "  Каталог: ${BASE}"
    echo "  Docker-сеть: openhands-net"
    echo "  Docker-контейнер: openhands-agent"
    echo ""
    echo "Файлы в ${BASE}:"
    find "${BASE}" -type f 2>/dev/null | head -30 || echo "  (каталог не существует)"
    echo ""
    echo "Размер:"
    du -sh "${BASE}" 2>/dev/null || echo "  (не существует)"
    exit 0
fi

echo "=== УДАЛЕНИЕ ==="
cd "${BASE}" 2>/dev/null || true

# Остановить и удалить контейнер
docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true

# Удалить сеть
docker network rm openhands-net 2>/dev/null || true

# Удалить каталог
sudo rm -rf "${BASE}"

echo ""
echo "Удалено: ${BASE}"
echo "Удалена Docker-сеть: openhands-net"
