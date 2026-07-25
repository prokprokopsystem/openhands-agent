#!/usr/bin/bash
# OpenHands Agent Canvas — полное удаление тестового запуска
# Без параметра: preview. С --confirm-destroy-test-data: удаление.
set -euo pipefail

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
REMOVE_FW="${BASE}/deployment/network/remove-egress-rules.sh"
UNIT="openhands-agent.service"

MODE="${1:-}"

if [ "${MODE}" != "--confirm-destroy-test-data" ]; then
    echo "=== PURGE PREVIEW ==="
    echo "Для удаления: $0 --confirm-destroy-test-data"
    echo ""
    echo "Будет удалено:"
    echo "  systemd unit: ${UNIT}"
    echo "  Docker-сеть: openhands-net"
    echo "  Docker-контейнер: openhands-agent"
    echo "  Каталог: ${BASE}"
    echo ""
    if [ -d "${BASE}" ]; then
        echo "Файлы:"
        find "${BASE}" -type f 2>/dev/null | head -30
        echo ""
        echo "Размер:"
        du -sh "${BASE}" 2>/dev/null
    else
        echo "(каталог не существует)"
    fi
    exit 0
fi

echo "=== PURGE ==="

# 1. Остановить systemd unit
if systemctl is-active --quiet "${UNIT}" 2>/dev/null; then
    echo "Остановка ${UNIT}..."
    systemctl stop "${UNIT}"
fi

# 2. Disable unit
if systemctl is-enabled --quiet "${UNIT}" 2>/dev/null; then
    echo "Отключение ${UNIT}..."
    systemctl disable "${UNIT}"
fi

# 3. Удалить firewall (ОШИБКА БЛОКИРУЕТ продолжение)
if [ -f "${REMOVE_FW}" ]; then
    echo "Удаление egress-правил..."
    sudo /usr/bin/bash "${REMOVE_FW}"
    echo "Firewall удалён."
else
    echo "❌ ${REMOVE_FW} не найден"
    exit 1
fi

# Проверить отсутствие цепочек
if iptables -nL OPENHANDS-EGRESS >/dev/null 2>&1; then
    echo "❌ Цепочка OPENHANDS-EGRESS всё ещё существует"
    exit 1
fi

# 4. Compose down
cd "${BASE}" 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true

# 5. Удалить unit-файл
if [ -f "/etc/systemd/system/${UNIT}" ]; then
    rm -f "/etc/systemd/system/${UNIT}"
    systemctl daemon-reload
fi

# 6. Удалить Docker-сеть
docker network rm openhands-net 2>/dev/null || true

# 7. Удалить каталог (без выхода за ФС)
if [ -d "${BASE}" ]; then
    rm -rf "${BASE}"
fi

echo ""
echo "✅ Purge завершён."
