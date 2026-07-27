#!/usr/bin/bash
# OpenHands Agent — broker-wrapper
# Единственная точка входа через SSH forced command.
# Читает реестр /etc/openhands-broker/tools.yaml, проверяет команду,
# подставляет секреты, журналирует, выполняет, проверяет результат.
#
# Вызов: broker-wrapper.sh <инструмент> [параметр=значение...] [--dry-run]
#
set -euo pipefail

BROKER_BASE="/etc/openhands-broker"
TOOLS_FILE="${BROKER_BASE}/tools.yaml"
SECRETS_DIR="${BROKER_BASE}/secrets"
LOG_DIR="/var/log/openhands-broker"
ACTIONS_LOG="${LOG_DIR}/actions.log"
ERROR_LOG="${LOG_DIR}/error.log"
TIMEOUT_SEC=120

# --- Утилиты ---
log_action() {
    local tool="$1" params="$2" exit_code="$3" duration="$4" msg="$5"
    local ts
    ts="$(date --utc +"%Y-%m-%dT%H:%M:%SZ")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${ts}" "${tool}" "${params}" "${exit_code}" "${duration}" "${msg}" \
        >> "${ACTIONS_LOG}"
}

log_error() {
    local ts
    ts="$(date --utc +"%Y-%m-%dT%H:%M:%SZ")"
    echo "${ts} $*" >> "${ERROR_LOG}"
}

die() {
    echo "ERROR: $*" >&2
    log_error "$*"
    exit 1
}

# --- Парсинг аргументов ---
[ $# -ge 1 ] || die "Usage: broker-wrapper.sh <tool> [param=value...] [--dry-run]"

TOOL_NAME="$1"
shift

DRY_RUN=false
declare -A PARAMS
for arg in "$@"; do
    if [ "${arg}" = "--dry-run" ]; then
        DRY_RUN=true
    elif [[ "${arg}" == *=* ]]; then
        key="${arg%%=*}"
        val="${arg#*=}"
        PARAMS["${key}"]="${val}"
    else
        die "Unknown argument: ${arg}"
    fi
done

# --- Чтение реестра ---
[ -f "${TOOLS_FILE}" ] || die "tools.yaml not found: ${TOOLS_FILE}"

# Проверяем наличие yq или python3 для парсинга YAML
if command -v yq &>/dev/null; then
    parse_cmd() { yq -r "$1" "${TOOLS_FILE}" 2>/dev/null; }
elif command -v python3 &>/dev/null; then
    parse_cmd() {
        python3 -c "
import yaml, sys
with open('${TOOLS_FILE}') as f:
    data = yaml.safe_load(f)
tools = data.get('tools', [])
for t in tools:
    if t.get('name') == '${TOOL_NAME}':
        result = t $1
        print(result if result is not None else 'null')
        sys.exit(0)
sys.exit(1)
" 2>/dev/null || echo "null"
    }
else
    die "Neither yq nor python3 with PyYAML available"
fi

TOOL_EXECUTE=$(parse_cmd '.execute // "null"')
TOOL_VERIFY=$(parse_cmd '.verify // "null"')
TOOL_ROLLBACK=$(parse_cmd '.rollback // "null"')
TOOL_RISK=$(parse_cmd '.risk // "null"')
TOOL_SECRETS=$(parse_cmd '.secrets // []')

[ "${TOOL_EXECUTE}" != "null" ] || die "Unknown tool: ${TOOL_NAME}"

# --- Проверка уровня риска ---
# Уровень C требует явного флага --confirm-level-c
if [ "${TOOL_RISK}" = "C" ]; then
    if [ "${DRY_RUN}" = "true" ]; then
        echo "DRY-RUN: Level C tool '${TOOL_NAME}' requires --confirm-level-c"
        exit 0
    fi
    die "Level C tool '${TOOL_NAME}' requires explicit user confirmation via --confirm-level-c flag"
fi

# --- Подстановка параметров ---
# Заменяем {{param}} на значение из PARAMS или default из YAML
EXECUTE_CMD="${TOOL_EXECUTE}"

# Подстановка параметров из PARAMS
for key in "${!PARAMS[@]}"; do
    EXECUTE_CMD="${EXECUTE_CMD//\{\{$key\}\}/${PARAMS[$key]}}"
done

# Подстановка секретов: {{secret:NAME}} → значение из файла
if [ "${TOOL_SECRETS}" != "null" ] && [ "${TOOL_SECRETS}" != "[]" ]; then
    while echo "${EXECUTE_CMD}" | grep -q '{{secret:'; do
        SECRET_NAME=$(echo "${EXECUTE_CMD}" | sed -n 's/.*{{secret:\([^}]*\)}}.*/\1/p')
        SECRET_FILE="${SECRETS_DIR}/${SECRET_NAME}"
        [ -f "${SECRET_FILE}" ] || die "Secret not found: ${SECRET_NAME}"
        SECRET_VALUE=$(cat "${SECRET_FILE}")
        # Маскируем в выводе для журнала
        EXECUTE_CMD="${EXECUTE_CMD//\{\{secret:${SECRET_NAME}\}\}/${SECRET_VALUE}}"
    done
fi

# --- Журналирование (без секретов) ---
LOG_PARAMS=""
for key in "${!PARAMS[@]}"; do
    LOG_PARAMS="${LOG_PARAMS} ${key}=***"
done
LOG_PARAMS="$(echo "${LOG_PARAMS}" | xargs)"

START_TS=$(date +%s)
echo "TOOL: ${TOOL_NAME} [${TOOL_RISK}]"
echo "PARAMS:${LOG_PARAMS}"
[ "${DRY_RUN}" = "true" ] && echo "MODE: DRY-RUN"

# --- Dry-run ---
if [ "${DRY_RUN}" = "true" ]; then
    echo "DRY-RUN: Would execute: ${EXECUTE_CMD}"
    if [ "${TOOL_VERIFY}" != "null" ]; then
        echo "DRY-RUN: Would verify: ${TOOL_VERIFY}"
    fi
    if [ "${TOOL_ROLLBACK}" != "null" ]; then
        echo "DRY-RUN: Rollback available: ${TOOL_ROLLBACK}"
    fi
    exit 0
fi

# --- Выполнение ---
set +e
OUTPUT=$(timeout "${TIMEOUT_SEC}" bash -c "${EXECUTE_CMD}" 2>&1)
EXIT_CODE=$?
set -e

DURATION=$(( $(date +%s) - START_TS ))

# --- Проверка результата ---
if [ ${EXIT_CODE} -eq 0 ] && [ "${TOOL_VERIFY}" != "null" ]; then
    set +e
    VERIFY_OUTPUT=$(timeout 10 bash -c "${TOOL_VERIFY}" 2>&1)
    VERIFY_CODE=$?
    set -e
    if [ ${VERIFY_CODE} -ne 0 ]; then
        log_action "${TOOL_NAME}" "${LOG_PARAMS}" "${EXIT_CODE}" "${DURATION}" "VERIFY_FAILED: ${VERIFY_OUTPUT}"
        log_error "${TOOL_NAME}: execute OK but verify failed: ${VERIFY_OUTPUT}"
        echo "WARN: execute OK but verify failed: ${VERIFY_OUTPUT}"
        # Пробуем откат
        if [ "${TOOL_ROLLBACK}" != "null" ]; then
            echo "ROLLBACK: executing rollback..."
            set +e
            ROLLBACK_OUTPUT=$(timeout "${TIMEOUT_SEC}" bash -c "${TOOL_ROLLBACK}" 2>&1)
            log_action "${TOOL_NAME}" "${LOG_PARAMS}" "$?" "${DURATION}" "ROLLBACK: ${ROLLBACK_OUTPUT}"
            set -e
        fi
        exit ${VERIFY_CODE}
    fi
fi

# --- Результат ---
echo "${OUTPUT}"
log_action "${TOOL_NAME}" "${LOG_PARAMS}" "${EXIT_CODE}" "${DURATION}" "OK"
exit ${EXIT_CODE}
