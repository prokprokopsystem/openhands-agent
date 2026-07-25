#!/usr/bin/bash
# OpenHands Agent Canvas — health watchdog
# Отслеживает docker healthcheck контейнера.
# 3 последовательных unhealthy → stop контейнера → exit 1.
# Не раскрывает секреты. Не затрагивает другие контейнеры.
set -euo pipefail

CONTAINER="openhands-agent"
MAX_UNHEALTHY=3
START_PERIOD=90
CHECK_INTERVAL=10

echo "[watchdog] Ожидание контейнера ${CONTAINER}..."

for i in $(seq 1 30); do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
        echo "[watchdog] Контейнер найден."
        break
    fi
    sleep 2
done

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
    echo "[watchdog] ❌ Контейнер не появился"
    exit 1
fi

echo "[watchdog] Ожидание start_period (${START_PERIOD}s)..."
sleep "${START_PERIOD}"

UNHEALTHY_COUNT=0

while true; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
        echo "[watchdog] ❌ Контейнер исчез или завершился"
        exit 1
    fi

    STATUS=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo "unknown")

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
                docker logs --tail 30 "${CONTAINER}" 2>/dev/null | grep -viE 'token|key|secret|password|bearer|api_key' || true
                echo "[watchdog] Остановка контейнера..."
                docker stop "${CONTAINER}" 2>/dev/null || true
                exit 1
            fi
            ;;
        *)
            echo "[watchdog] ❌ Неизвестный статус: ${STATUS}"
            exit 1
            ;;
    esac

    sleep "${CHECK_INTERVAL}"
done
