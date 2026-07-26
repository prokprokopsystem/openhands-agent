#!/usr/bin/bash
# OpenHands Agent Canvas — health watchdog
# Отслеживает docker healthcheck контейнера.
# 3 последовательных unhealthy → stop контейнера → exit 1.
# Не раскрывает секреты. Не затрагивает другие контейнеры.
set -euo pipefail

CONTAINER="openhands-agent"
MAX_UNHEALTHY="${WATCHDOG_MAX_UNHEALTHY:-3}"
START_PERIOD="${WATCHDOG_START_PERIOD:-90}"
CHECK_INTERVAL="${WATCHDOG_CHECK_INTERVAL:-10}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
STOP_REQUESTED=false
SLEEP_PID=""

on_signal() {
    local rc

    STOP_REQUESTED=true
    if [ -n "${SLEEP_PID}" ] && kill -0 "${SLEEP_PID}" 2>/dev/null; then
        kill -TERM "${SLEEP_PID}" 2>/dev/null || true
    fi
    if [ -n "${SLEEP_PID}" ]; then
        set +e
        wait "${SLEEP_PID}"
        rc=$?
        set -e
        SLEEP_PID=""
        echo "[watchdog] Управляемый sleep завершён: ${rc}"
    fi
    exit 0
}

managed_sleep() {
    local duration="$1"
    local rc

    sleep "${duration}" &
    SLEEP_PID=$!
    set +e
    wait "${SLEEP_PID}"
    rc=$?
    set -e
    SLEEP_PID=""

    if ${STOP_REQUESTED}; then
        exit 0
    fi
    return "${rc}"
}

trap on_signal SIGTERM SIGINT

echo "[watchdog] Ожидание контейнера ${CONTAINER}..."

for i in $(seq 1 30); do
    if "${DOCKER_BIN}" ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
        echo "[watchdog] Контейнер найден."
        break
    fi
    managed_sleep 2
done

if ! "${DOCKER_BIN}" ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
    echo "[watchdog] ❌ Контейнер не появился"
    exit 1
fi

echo "[watchdog] Ожидание start_period (${START_PERIOD}s)..."
managed_sleep "${START_PERIOD}"

UNHEALTHY_COUNT=0

while true; do
    if ! "${DOCKER_BIN}" ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
        echo "[watchdog] ❌ Контейнер исчез или завершился"
        exit 1
    fi

    STATUS=$("${DOCKER_BIN}" inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo "unknown")

    case "${STATUS}" in
        healthy)
            UNHEALTHY_COUNT=0
            ;;
        starting)
            ;;
        unhealthy)
            UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1))
            echo "[watchdog] ⚠️  Unhealthy (${UNHEALTHY_COUNT}/${MAX_UNHEALTHY})"
            if [ "${UNHEALTHY_COUNT}" -ge "${MAX_UNHEALTHY}" ]; then
                echo "[watchdog] ❌ ${MAX_UNHEALTHY} последовательных unhealthy"
                echo "[watchdog] Последние логи (без секретов):"
                "${DOCKER_BIN}" logs --tail 30 "${CONTAINER}" 2>/dev/null | grep -viE 'token|key|secret|password|bearer|api_key' || true
                echo "[watchdog] Остановка контейнера..."
                "${DOCKER_BIN}" stop "${CONTAINER}" 2>/dev/null || true
                exit 1
            fi
            ;;
        *)
            echo "[watchdog] ❌ Неизвестный статус: ${STATUS}"
            exit 1
            ;;
    esac

    managed_sleep "${CHECK_INTERVAL}"
done
