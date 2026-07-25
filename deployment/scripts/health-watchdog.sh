#!/usr/bin/bash
# OpenHands Agent Canvas — health watchdog
# Отслеживает docker healthcheck контейнера.
# 3 последовательных unhealthy → остановка контейнера + exit 1.
# Не раскрывает секреты. Не затрагивает другие контейнеры.
set -euo pipefail

CONTAINER="openhands-agent"
MAX_UNHEALTHY=3
START_PERIOD=90   # дать время на загрузку (healthcheck start_period 60s + запас)
CHECK_INTERVAL=10

echo "[watchdog] Старт. Ожидание контейнера ${CONTAINER}..."

# Ждать появления контейнера
for i in $(seq 1 30); do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
        echo "[watchdog] Контейнер ${CONTAINER} найден."
        break
    fi
    sleep 2
done

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
    echo "[watchdog] ❌ Контейнер ${CONTAINER} не появился за 60 секунд"
    exit 1
fi

# Ждать start_period
echo "[watchdog] Ожидание start_period (${START_PERIOD}s)..."
sleep "${START_PERIOD}"

UNHEALTHY_COUNT=0

while true; do
    # Проверить, существует ли контейнер
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
        echo "[watchdog] ❌ Контейнер ${CONTAINER} исчез или завершился"
        exit 1
    fi

    STATUS=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo "unknown")

    case "${STATUS}" in
        healthy)
            UNHEALTHY_COUNT=0
            ;;
        starting)
            # Продолжаем ждать
            ;;
        unhealthy)
            UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1))
            echo "[watchdog] ⚠️  Unhealthy (${UNHEALTHY_COUNT}/${MAX_UNHEALTHY})"
            if [ "${UNHEALTHY_COUNT}" -ge "${MAX_UNHEALTHY}" ]; then
                echo "[watchdog] ❌ ${MAX_UNHEALTHY} последовательных unhealthy."
                echo "[watchdog] Последние логи:"
                docker logs --tail 30 "${CONTAINER}" 2>/dev/null | grep -viE 'token|key|secret|password|bearer' || true
                echo "[watchdog] Состояние health:"
                docker inspect -f '{{json .State.Health}}' "${CONTAINER}" 2>/dev/null | python3 -m json.tool 2>/dev/null || true
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
