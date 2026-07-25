#!/usr/bin/bash
# OpenHands Agent Canvas — supervised lifecycle
# Запускает docker compose up (foreground) + health-watchdog.
# Каждый дочерний PID ожидается ровно один раз.
# Любое самостоятельное завершение дочернего процесса считается failure.
# SIGTERM/SIGINT → конечная штатная остановка (exit 0).
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-/srv/openhands-agent/deployment/compose.yaml}"
WATCHDOG="${WATCHDOG:-/srv/openhands-agent/deployment/scripts/health-watchdog.sh}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
POLL_INTERVAL="${SUPERVISOR_POLL_INTERVAL:-1}"
TERM_TIMEOUT="${SUPERVISOR_TERM_TIMEOUT:-10}"
EXIT_GRACE="${SUPERVISOR_EXIT_GRACE:-0.2}"

COMPOSE_PID=""
WATCHDOG_PID=""
COMPOSE_RC=""
WATCHDOG_RC=""
COMPOSE_COLLECTED=false
WATCHDOG_COLLECTED=false
TERMINATED_BY_SIGNAL=false

on_signal() {
    TERMINATED_BY_SIGNAL=true
}

trap on_signal SIGTERM SIGINT

wait_pid() {
    local pid="$1"
    local result_var="$2"
    local rc

    set +e
    wait "${pid}"
    rc=$?
    set -e

    printf -v "${result_var}" '%d' "${rc}"
}

collect_compose() {
    if ! ${COMPOSE_COLLECTED}; then
        wait_pid "${COMPOSE_PID}" COMPOSE_RC
        COMPOSE_COLLECTED=true
        echo "[supervisor] compose collected exit=${COMPOSE_RC}"
    fi
}

collect_watchdog() {
    if ! ${WATCHDOG_COLLECTED}; then
        wait_pid "${WATCHDOG_PID}" WATCHDOG_RC
        WATCHDOG_COLLECTED=true
        echo "[supervisor] watchdog collected exit=${WATCHDOG_RC}"
    fi
}

terminate_child() {
    local pid="$1"
    local name="$2"
    local deadline

    if ! kill -0 "${pid}" 2>/dev/null; then
        return 0
    fi

    echo "[supervisor] TERM → ${name} (${pid})"
    kill -TERM "${pid}" 2>/dev/null || true
    deadline=$((SECONDS + TERM_TIMEOUT))

    while kill -0 "${pid}" 2>/dev/null && [ "${SECONDS}" -lt "${deadline}" ]; do
        sleep "${POLL_INTERVAL}" || true
    done

    if kill -0 "${pid}" 2>/dev/null; then
        echo "[supervisor] KILL → ${name} (${pid})"
        kill -KILL "${pid}" 2>/dev/null || true
    fi
}

compose_down() {
    local rc

    set +e
    timeout "${TERM_TIMEOUT}" "${DOCKER_BIN}" compose -f "${COMPOSE_FILE}" down --remove-orphans
    rc=$?
    set -e

    if [ "${rc}" -ne 0 ]; then
        echo "[supervisor] compose down exit=${rc}"
    fi
}

stop_and_collect_all() {
    terminate_child "${WATCHDOG_PID}" "watchdog"
    compose_down
    terminate_child "${COMPOSE_PID}" "compose"
    collect_watchdog
    collect_compose
}

echo "[supervisor] Запуск compose..."
"${DOCKER_BIN}" compose -f "${COMPOSE_FILE}" up &
COMPOSE_PID=$!

echo "[supervisor] Запуск watchdog..."
/usr/bin/bash "${WATCHDOG}" &
WATCHDOG_PID=$!

while true; do
    if ${TERMINATED_BY_SIGNAL}; then
        echo "[supervisor] Получен сигнал штатной остановки."
        stop_and_collect_all
        exit 0
    fi

    COMPOSE_ALIVE=true
    WATCHDOG_ALIVE=true
    kill -0 "${COMPOSE_PID}" 2>/dev/null || COMPOSE_ALIVE=false
    kill -0 "${WATCHDOG_PID}" 2>/dev/null || WATCHDOG_ALIVE=false

    if ! ${COMPOSE_ALIVE} || ! ${WATCHDOG_ALIVE}; then
        break
    fi

    sleep "${POLL_INTERVAL}" || true
done

# Повторная проверка закрывает гонку между двумя kill -0.
kill -0 "${COMPOSE_PID}" 2>/dev/null || COMPOSE_ALIVE=false
kill -0 "${WATCHDOG_PID}" 2>/dev/null || WATCHDOG_ALIVE=false

if ! ${COMPOSE_ALIVE}; then
    collect_compose
fi
if ! ${WATCHDOG_ALIVE}; then
    collect_watchdog
fi

# Дать второму процессу короткое ограниченное окно завершиться самостоятельно.
# Это сохраняет его настоящий exit code при почти одновременном выходе обоих детей.
if ${COMPOSE_ALIVE} || ${WATCHDOG_ALIVE}; then
    sleep "${EXIT_GRACE}" || true

    if ${TERMINATED_BY_SIGNAL}; then
        echo "[supervisor] Получен сигнал штатной остановки."
        stop_and_collect_all
        exit 0
    fi

    kill -0 "${COMPOSE_PID}" 2>/dev/null || COMPOSE_ALIVE=false
    kill -0 "${WATCHDOG_PID}" 2>/dev/null || WATCHDOG_ALIVE=false

    if ! ${COMPOSE_ALIVE}; then
        collect_compose
    fi
    if ! ${WATCHDOG_ALIVE}; then
        collect_watchdog
    fi
fi

if ! ${COMPOSE_ALIVE} && ${WATCHDOG_ALIVE}; then
    terminate_child "${WATCHDOG_PID}" "watchdog"
    collect_watchdog
elif ! ${WATCHDOG_ALIVE} && ${COMPOSE_ALIVE}; then
    compose_down
    terminate_child "${COMPOSE_PID}" "compose"
    collect_compose
else
    # Оба могли завершиться почти одновременно; собрать всё ещё не собранное.
    collect_compose
    collect_watchdog
fi

echo "[supervisor] Неожиданное завершение дочернего процесса: service failed."
exit 1
