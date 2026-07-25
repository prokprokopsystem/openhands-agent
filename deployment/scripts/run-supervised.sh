#!/usr/bin/bash
# OpenHands Agent Canvas — supervised lifecycle
# Запускает docker compose up (foreground) + health-watchdog.
# Падение любого процесса → остановка второго → ненулевой exit code.
# SIGTERM от systemd — штатная остановка (exit 0).
set -euo pipefail

COMPOSE_FILE="/srv/openhands-agent/deployment/compose.yaml"
WATCHDOG="/srv/openhands-agent/deployment/scripts/health-watchdog.sh"

COMPOSE_PID=""
WATCHDOG_PID=""
EXIT_CODE=0
TERMINATED_BY_SIGNAL=false

cleanup() {
    # SIGTERM/SIGINT — штатная остановка systemd
    if [ -n "${WATCHDOG_PID:-}" ] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
        kill "${WATCHDOG_PID}" 2>/dev/null || true
    fi
    if [ -n "${COMPOSE_PID:-}" ] && kill -0 "${COMPOSE_PID}" 2>/dev/null; then
        kill "${COMPOSE_PID}" 2>/dev/null || true
    fi
}

trap 'TERMINATED_BY_SIGNAL=true; cleanup' SIGTERM SIGINT

echo "[supervisor] Запуск docker compose up..."
docker compose -f "${COMPOSE_FILE}" up &
COMPOSE_PID=$!

sleep 3

echo "[supervisor] Запуск watchdog..."
/usr/bin/bash "${WATCHDOG}" &
WATCHDOG_PID=$!

# Ждать завершения любого
while kill -0 "${COMPOSE_PID}" 2>/dev/null && kill -0 "${WATCHDOG_PID}" 2>/dev/null; do
    sleep 2
done

# Определить, кто завершился первым
COMPOSE_DONE=false
WATCHDOG_DONE=false

if ! kill -0 "${COMPOSE_PID}" 2>/dev/null; then
    COMPOSE_DONE=true
fi
if ! kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    WATCHDOG_DONE=true
fi

# Безопасно получить exit codes (set -e не должен убить скрипт при wait)
if ${COMPOSE_DONE}; then
    set +e
    wait "${COMPOSE_PID}" 2>/dev/null
    COMPOSE_RC=$?
    set -e
    echo "[supervisor] docker compose завершился (exit=${COMPOSE_RC})"
    if [ "${COMPOSE_RC}" -ne 0 ] && ! ${TERMINATED_BY_SIGNAL}; then
        EXIT_CODE=1
    fi
    # Остановить watchdog
    if [ -n "${WATCHDOG_PID:-}" ] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
        kill "${WATCHDOG_PID}" 2>/dev/null || true
    fi
fi

if ${WATCHDOG_DONE} && ! ${COMPOSE_DONE}; then
    set +e
    wait "${WATCHDOG_PID}" 2>/dev/null
    WATCHDOG_RC=$?
    set -e
    echo "[supervisor] watchdog завершился (exit=${WATCHDOG_RC})"
    if [ "${WATCHDOG_RC}" -ne 0 ]; then
        EXIT_CODE=1
        # Остановить compose
        if [ -n "${COMPOSE_PID:-}" ] && kill -0 "${COMPOSE_PID}" 2>/dev/null; then
            docker compose -f "${COMPOSE_FILE}" down 2>/dev/null
        fi
    fi
fi

# Если оба завершились почти одновременно
if ${COMPOSE_DONE} && ${WATCHDOG_DONE}; then
    set +e
    wait "${COMPOSE_PID}" 2>/dev/null
    COMPOSE_RC=$?
    wait "${WATCHDOG_PID}" 2>/dev/null
    WATCHDOG_RC=$?
    set -e
    if [ "${COMPOSE_RC}" -ne 0 ] || [ "${WATCHDOG_RC}" -ne 0 ]; then
        EXIT_CODE=1
    fi
fi

if ${TERMINATED_BY_SIGNAL}; then
    echo "[supervisor] Штатное завершение по сигналу."
    exit 0
fi

if [ "${EXIT_CODE}" -ne 0 ]; then
    echo "[supervisor] Service failed."
fi

exit "${EXIT_CODE}"
