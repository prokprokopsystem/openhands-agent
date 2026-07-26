#!/usr/bin/bash
# OpenHands Agent Canvas — остановка (оболочка над systemd)
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
STOP_VERIFY_DELAY="${STOP_VERIFY_DELAY:-2}"
FAIL=0

echo "=== OpenHands Agent Canvas — остановка через systemd ==="

sudo systemctl stop openhands-agent.service

sleep "${STOP_VERIFY_DELAY}"

# Проверка: контейнер остановлен
if ! RUNNING_CONTAINERS=$("${DOCKER_BIN}" ps --format '{{.Names}}' 2>&1); then
    echo "❌ Не удалось проверить состояние контейнера: ${RUNNING_CONTAINERS}" >&2
    FAIL=1
elif grep -qx 'openhands-agent' <<<"${RUNNING_CONTAINERS}"; then
    echo "❌ Контейнер openhands-agent всё ещё работает" >&2
    FAIL=1
else
    echo "✅ Контейнер остановлен"
fi

check_chain_absent() {
    local chain="$1"
    local output

    if output=$(sudo iptables -nL "${chain}" 2>&1); then
        echo "❌ Цепочка ${chain} всё ещё существует" >&2
        FAIL=1
    elif grep -qiE 'No chain/target/match by that name|Chain .* does not exist' <<<"${output}"; then
        echo "✅ Цепочка ${chain} удалена"
    else
        echo "❌ Не удалось проверить цепочку ${chain}: ${output}" >&2
        FAIL=1
    fi
}

check_chain_absent OPENHANDS-EGRESS
check_chain_absent OPENHANDS-INPUT

if [ "${FAIL}" -ne 0 ]; then
    echo "❌ Остановка или проверка очистки завершилась ошибкой" >&2
    exit "${FAIL}"
fi

echo ""
echo "Состояние сохранено: /srv/openhands-agent/config/"
echo "Workspace сохранён: /srv/openhands-agent/test-workspace/"
