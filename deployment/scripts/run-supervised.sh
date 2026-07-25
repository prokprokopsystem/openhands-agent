#!/usr/bin/bash
# OpenHands Agent Canvas — supervised lifecycle
# Запускает foreground docker compose up + watchdog.
# При падении любого процесса — завершает второй и выходит с ошибкой.
set -euo pipefail

COMPOSE_FILE="/srv/openhands-agent/deployment/compose.yaml"
WATCHDOG="/srv/openhands-agent/deployment/scripts/health-watchdog.sh"

cleanup() {
    echo "[supervisor] Завершение..."
    if [ -n "${WATCHDOG_PID:-}" ] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
        kill "${WATCHDOG_PID}" 2>/dev/null || true
        wait "${WATCHDOG_PID}" 2>/dev/null || true
    fi
    if [ -n "${COMPOSE_PID:-}" ] && kill -0 "${COMPOSE_PID}" 2>/dev/null; then
        docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
    fi
}

trap cleanup EXIT

echo "[supervisor] Запуск docker compose up (foreground)..."
docker compose -f "${COMPOSE_FILE}" up &
COMPOSE_PID=$!

# Дать compose время создать контейнер
sleep 3

echo "[supervisor] Запуск watchdog..."
/usr/bin/bash "${WATCHDOG}" &
WATCHDOG_PID=$!

# Ждать завершения любого из процессов
while kill -0 "${COMPOSE_PID}" 2>/dev/null && kill -0 "${WATCHDOG_PID}" 2>/dev/null; do
    sleep 2
done

# Определить, кто упал
COMPOSE_DEAD=false
WATCHDOG_DEAD=false

if ! kill -0 "${COMPOSE_PID}" 2>/dev/null; then
    COMPOSE_DEAD=true
    wait "${COMPOSE_PID}" 2>/dev/null || true
    COMPOSE_EXIT=$?
    echo "[supervisor] docker compose завершился (exit=${COMPOSE_EXIT})"
fi

if ! kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    WATCHDOG_DEAD=true
    wait "${WATCHDOG_PID}" 2>/dev/null || true
    WATCHDOG_EXIT=$?
    echo "[supervisor] watchdog завершился (exit=${WATCHDOG_EXIT})"
fi

# Если любой упал — это failure
if ${COMPOSE_DEAD} || ${WATCHDOG_DEAD}; then
    echo "[supervisor] ❌ Один из процессов завершился — service failed"
    exit 1
fi

echo "[supervisor] Штатное завершение."
