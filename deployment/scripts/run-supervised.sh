#!/usr/bin/bash
# OpenHands Agent Canvas — supervised lifecycle
# Запускает docker compose up (foreground) + health-watchdog.
# Каждый PID ожидается ровно один раз.
# Первый упавший → остановка второго → сбор его кода.
# SIGTERM → штатная остановка (exit 0).
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-/srv/openhands-agent/deployment/compose.yaml}"
WATCHDOG="${WATCHDOG:-/srv/openhands-agent/deployment/scripts/health-watchdog.sh}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

COMPOSE_PID=""
WATCHDOG_PID=""
EXIT_CODE=0
TERMINATED_BY_SIGNAL=false

cleanup() {
    if [ -n "${WATCHDOG_PID:-}" ] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
        kill "${WATCHDOG_PID}" 2>/dev/null || true
    fi
    if [ -n "${COMPOSE_PID:-}" ] && kill -0 "${COMPOSE_PID}" 2>/dev/null; then
        kill "${COMPOSE_PID}" 2>/dev/null || true
    fi
}

trap 'TERMINATED_BY_SIGNAL=true; cleanup' SIGTERM SIGINT

# Функция безопасного сбора exit code (ровно один wait на PID)
wait_pid() {
    local pid="$1"
    local varname="$2"
    set +e
    wait "${pid}" 2>/dev/null
    eval "${varname}=$?"
    set -e
}

echo "[supervisor] Запуск compose..."
"${DOCKER_BIN}" compose -f "${COMPOSE_FILE}" up &
COMPOSE_PID=$!

sleep 3

echo "[supervisor] Запуск watchdog..."
/usr/bin/bash "${WATCHDOG}" &
WATCHDOG_PID=$!

# Ждать завершения любого
while kill -0 "${COMPOSE_PID}" 2>/dev/null && kill -0 "${WATCHDOG_PID}" 2>/dev/null; do
    sleep 2
done

# Определить, кто завершился
COMPOSE_DEAD=false
WATCHDOG_DEAD=false
if ! kill -0 "${COMPOSE_PID}" 2>/dev/null; then COMPOSE_DEAD=true; fi
if ! kill -0 "${WATCHDOG_PID}" 2>/dev/null; then WATCHDOG_DEAD=true; fi

# Собрать коды: каждый PID ровно один раз
if ${COMPOSE_DEAD}; then
    wait_pid "${COMPOSE_PID}" COMPOSE_RC
    echo "[supervisor] compose exit=${COMPOSE_RC}"
    if [ "${COMPOSE_RC}" -ne 0 ] && ! ${TERMINATED_BY_SIGNAL}; then
        EXIT_CODE=1
    fi
    # Остановить watchdog
    if ! ${WATCHDOG_DEAD} && [ -n "${WATCHDOG_PID:-}" ] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
        kill "${WATCHDOG_PID}" 2>/dev/null || true
        # Дождаться остановленного watchdog
        wait_pid "${WATCHDOG_PID}" WATCHDOG_RC
        echo "[supervisor] watchdog stopped, exit=${WATCHDOG_RC}"
    fi
fi

if ${WATCHDOG_DEAD} && ! ${COMPOSE_DEAD}; then
    wait_pid "${WATCHDOG_PID}" WATCHDOG_RC
    echo "[supervisor] watchdog exit=${WATCHDOG_RC}"
    if [ "${WATCHDOG_RC}" -ne 0 ]; then
        EXIT_CODE=1
    fi
    # Остановить compose
    if [ -n "${COMPOSE_PID:-}" ] && kill -0 "${COMPOSE_PID}" 2>/dev/null; then
        "${DOCKER_BIN}" compose -f "${COMPOSE_FILE}" down 2>/dev/null
        # Дождаться остановленного compose
        wait_pid "${COMPOSE_PID}" COMPOSE_RC
        echo "[supervisor] compose stopped, exit=${COMPOSE_RC}"
    fi
fi

# Если оба завершились одновременно — compose уже собран выше, watchdog тоже если compose убил его
# Нет ситуации двойного wait

if ${TERMINATED_BY_SIGNAL}; then
    echo "[supervisor] Штатное завершение по сигналу."
    exit 0
fi

if [ "${EXIT_CODE}" -ne 0 ]; then
    echo "[supervisor] Service failed."
fi

exit "${EXIT_CODE}"
