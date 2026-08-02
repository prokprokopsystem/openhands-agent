#!/usr/bin/bash
# OpenHands Agent Canvas — health watchdog
# После появления контейнера сверяет pinned SSH host key, затем отслеживает healthcheck.
# 3 последовательных unhealthy → stop контейнера → exit 1.
# Не раскрывает секреты. Не затрагивает другие контейнеры.
set -euo pipefail

CONTAINER="openhands-agent"
MAX_UNHEALTHY="${WATCHDOG_MAX_UNHEALTHY:-3}"
START_PERIOD="${WATCHDOG_START_PERIOD:-90}"
CHECK_INTERVAL="${WATCHDOG_CHECK_INTERVAL:-10}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
SSH_KEYSCAN_BIN="${SSH_KEYSCAN_BIN:-ssh-keyscan}"
SSH_KEYGEN_BIN="${SSH_KEYGEN_BIN:-ssh-keygen}"
BROKER_HOST="${BROKER_HOST:-10.89.0.1}"
BROKER_PORT="${BROKER_PORT:-22}"
BROKER_KNOWN_HOSTS="${BROKER_KNOWN_HOSTS:-/etc/openhands-broker/client_known_hosts}"
HOST_KEY_RETRIES="${WATCHDOG_HOST_KEY_RETRIES:-10}"
HOST_KEY_RETRY_INTERVAL="${WATCHDOG_HOST_KEY_RETRY_INTERVAL:-2}"
HOST_SCAN_TMP_DIR="${WATCHDOG_HOST_SCAN_TMP_DIR:-/run}"
STOP_REQUESTED=false
SLEEP_PID=""
HOST_SCAN_TMP=""

cleanup() {
    rm -f "${HOST_SCAN_TMP:-}"
}

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

verify_broker_host_key() {
    local pinned_fingerprint observed_fingerprint attempt
    local -a observed_host_keys

    [ -f "${BROKER_KNOWN_HOSTS}" ] \
        || { echo "[watchdog] ❌ Pinned broker known_hosts отсутствует"; return 1; }
    pinned_fingerprint="$("${SSH_KEYGEN_BIN}" -lf "${BROKER_KNOWN_HOSTS}" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')"
    [ -n "${pinned_fingerprint}" ] \
        || { echo "[watchdog] ❌ Не удалось прочитать pinned broker fingerprint"; return 1; }

    HOST_SCAN_TMP="$(mktemp "${HOST_SCAN_TMP_DIR}/openhands-broker-watchdog-hostkey.XXXXXX")"
    for attempt in $(seq 1 "${HOST_KEY_RETRIES}"); do
        : > "${HOST_SCAN_TMP}"
        "${SSH_KEYSCAN_BIN}" -4 -T 2 -p "${BROKER_PORT}" -t ed25519 "${BROKER_HOST}" \
            > "${HOST_SCAN_TMP}" 2>/dev/null || true
        mapfile -t observed_host_keys < <(
            awk '$2 == "ssh-ed25519" { print $2 " " $3 }' "${HOST_SCAN_TMP}" | sort -u
        )

        if [ "${#observed_host_keys[@]}" -gt 1 ]; then
            echo "[watchdog] ❌ SSH endpoint предъявил несколько ED25519 host keys"
            return 1
        fi
        if [ "${#observed_host_keys[@]}" -eq 1 ]; then
            observed_fingerprint="$("${SSH_KEYGEN_BIN}" -lf "${HOST_SCAN_TMP}" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')"
            [ -n "${observed_fingerprint}" ] \
                || { echo "[watchdog] ❌ Не удалось вычислить live broker fingerprint"; return 1; }
            if [ "${observed_fingerprint}" != "${pinned_fingerprint}" ]; then
                echo "[watchdog] ❌ Live broker SSH host key не совпадает с pinned key"
                return 1
            fi
            rm -f "${HOST_SCAN_TMP}"
            HOST_SCAN_TMP=""
            echo "[watchdog] Broker SSH host key подтверждён для ${BROKER_HOST}:${BROKER_PORT}."
            return 0
        fi

        if [ "${attempt}" -lt "${HOST_KEY_RETRIES}" ]; then
            managed_sleep "${HOST_KEY_RETRY_INTERVAL}"
        fi
    done

    echo "[watchdog] ❌ Broker SSH endpoint ${BROKER_HOST}:${BROKER_PORT} недоступен для host-key verification"
    return 1
}

trap cleanup EXIT
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

verify_broker_host_key

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
