#!/usr/bin/bash
# OpenHands Agent Canvas — supervised lifecycle
# Запускает docker compose up (foreground) + health-watchdog.
# Падение любого процесса → остановка второго → ненулевой exit code.
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

# Кто завершился первым?
if ! kill -0 "${COMPOSE_PID}" 2>/dev/null; then
    wait "${COMPOSE_PID}" 2>/dev/null
    COMPOSE_RC=$?
    echo "[supervisor] docker compose завершился (exit=${COMPOSE_RC})"
    if [ "${COMPOSE_RC}" -ne 0 ]; then
        EXIT_CODE=1
    fi
    # Остановить watchdog
    if [ -n "${WATCHDOG_PID:-}" ] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
        kill "${WATCHDOG_PID}" 2>/dev/null || true
    fi
fi

if [ -n "${WATCHDOG_PID:-}" ] && ! kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    wait "${WATCHDOG_PID}" 2>/dev/null
    WATCHDOG_RC=$?
    echo "[supervisor] watchdog завершился (exit=${WATCHDOG_RC})"
    if [ "${WATCHDOG_RC}" -ne 0 ]; then
        EXIT_CODE=1
        # Остановить compose
        if [ -n "${COMPOSE_PID:-}" ] && kill -0 "${COMPOSE_PID}" 2>/dev/null; then
            docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
        fi
    fi
fi

if ${TERMINATED_BY_SIGNAL}; then
    echo "[supervisor] Штатное завершение по сигналу."
    exit 0
fi

if [ "${EXIT_CODE}" -ne 0 ]; then
    echo "[supervisor] ❌ Service failed."
fi

exit "${EXIT_CODE}"
