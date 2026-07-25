#!/usr/bin/bash
# OpenHands Agent Canvas — полное удаление тестового запуска
# Без --confirm-destroy-test-data: только показывает что будет удалено.
# С --confirm-destroy-test-data: выполняет удаление.
# Не удаляет каталог при ошибке firewall.
set -euo pipefail

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
REMOVE_FW="${BASE}/deployment/network/remove-egress-rules.sh"

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

# 1. Остановить и удалить контейнер
cd "${BASE}" 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
echo "  ✅ Контейнер остановлен."

# 2. Удалить egress-правила (ОБЯЗАТЕЛЬНО, ошибка блокирует удаление каталога)
if [ -f "${REMOVE_FW}" ]; then
    echo "  Удаление egress-правил..."
    sudo /usr/bin/bash "${REMOVE_FW}"
    echo "  ✅ Egress-правила удалены."
else
    echo "  ⚠️  ${REMOVE_FW} не найден — пропуск egress."
fi

# 3. Удалить Docker-сеть
docker network rm openhands-net 2>/dev/null || true

# 4. Удалить каталог
sudo rm -rf "${BASE}"
echo ""
echo "✅ Удалено: ${BASE}"
echo "✅ Удалена Docker-сеть: openhands-net"
