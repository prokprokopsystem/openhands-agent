#!/usr/bin/bash
# OpenHands Agent Canvas — полное удаление тестового запуска
# Без параметра: preview. С --confirm-destroy-test-data: удаление.
set -euo pipefail

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
REMOVE_FW="${BASE}/deployment/network/remove-egress-rules.sh"
UNIT="openhands-agent.service"
FW_EGRESS="OPENHANDS-EGRESS"
FW_INPUT="OPENHANDS-INPUT"

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

# 3. Удалить firewall — ОШИБКА БЛОКИРУЕТ продолжение
if [ ! -f "${REMOVE_FW}" ]; then
    echo "ERROR: ${REMOVE_FW} не найден"
    exit 1
fi

echo "Удаление egress-правил..."
sudo /usr/bin/bash "${REMOVE_FW}"

# 4. Проверить отсутствие цепочек
if iptables -nL "${FW_EGRESS}" >/dev/null 2>&1; then
    echo "ERROR: цепочка ${FW_EGRESS} всё ещё существует после remove-egress-rules.sh"
    exit 1
fi

if iptables -nL "${FW_INPUT}" >/dev/null 2>&1; then
    echo "ERROR: цепочка ${FW_INPUT} всё ещё существует после remove-egress-rules.sh"
    exit 1
fi

echo "Firewall удалён."

# 5. Compose down — не скрывать ошибку
cd "${BASE}" 2>/dev/null || true
if ! docker compose -f "${COMPOSE_FILE}" down -v; then
    echo "ERROR: docker compose down завершился с ошибкой"
    exit 1
fi

# 6. Удалить unit-файл
if [ -f "/etc/systemd/system/${UNIT}" ]; then
    rm -f "/etc/systemd/system/${UNIT}"
    systemctl daemon-reload
fi

# 7. Удалить Docker-сеть — не скрывать ошибку
if docker network inspect openhands-net >/dev/null 2>&1; then
    if ! docker network rm openhands-net; then
        echo "ERROR: не удалось удалить сеть openhands-net"
        exit 1
    fi
fi

# 8. Удалить каталог с защитой от выхода за ФС
if [ -d "${BASE}" ]; then
    rm -rf --one-file-system -- "${BASE}"
fi

echo ""
echo "Purge завершён."
