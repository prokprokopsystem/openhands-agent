#!/usr/bin/bash
# OpenHands Agent — broker-wrapper
# Единственная точка входа через SSH forced command.
# Читает реестр /etc/openhands-broker/tools.yaml, проверяет команду,
# подставляет секреты, журналирует JSON, выполняет, проверяет результат.
#
# Вызывается sshd через authorized_keys с command=...
# SSH_ORIGINAL_COMMAND содержит: <tool> [param=value...] [--dry-run]
#
# Запрещён вывод секретов в stdout, stderr, dry-run и журналы.
set -euo pipefail

BROKER_BASE="${OPENHANDS_BROKER_BASE:-/etc/openhands-broker}"
TOOLS_FILE="${BROKER_BASE}/tools.yaml"
SECRETS_DIR="${BROKER_BASE}/secrets"
TIMEOUT_SEC=120
CHECK_TIMEOUT_SEC=10
MAX_OUTPUT_BYTES=65536
MAX_DIAG_BYTES=8192

# --- Блокировка на всё время выполнения wrapper ---
exec 8>/tmp/.openhands-broker-wrapper.lock
flock -n 8 || {
    echo "ERROR: another broker command is running" >&2
    exit 1
}

# --- Утилиты ---
LOGGER_BIN="$(command -v logger 2>/dev/null || true)"

audit_event() {
    local tool="$1" params="$2" exit_code="$3" duration="$4" status="$5"
    local record
    [ -n "${LOGGER_BIN}" ] || return 1
    record="$(python3 -c '
import json, sys
print(json.dumps({
    "tool": sys.argv[1],
    "params": sys.argv[2],
    "exit_code": int(sys.argv[3]),
    "duration_sec": int(sys.argv[4]),
    "status": sys.argv[5],
}, separators=(",", ":")))
' "${tool}" "${params}" "${exit_code}" "${duration}" "${status}")" || return 1
    "${LOGGER_BIN}" -p authpriv.notice -t openhands-broker -- "${record}"
}

audit_required() {
    audit_event "$@" || {
        echo "ERROR: broker audit unavailable; command not permitted" >&2
        exit 70
    }
}

die() {
    echo "ERROR: $*" >&2
    audit_event "${TOOL_NAME:-request}" "" 1 0 "REJECTED" >/dev/null 2>&1 || true
    exit 1
}

sanitize_log_param() {
    local val="$1"
    # Заменяем любые подозрительные символы
    echo "${val}" | tr -d '[:cntrl:]' | head -c 200
}

run_bounded() {
    local timeout_sec="$1" command_text="$2" output_limit="$3"
    local capture_limit output_bytes
    capture_limit=$((output_limit + 1))
    set +e
    RUN_OUTPUT="$(
        set +e
        timeout "${timeout_sec}" bash -c "${command_text}" 2>&1 | head -c "${capture_limit}"
        pipeline_status=("${PIPESTATUS[@]}")
        exit "${pipeline_status[0]}"
    )"
    RUN_CODE=$?
    set -e
    output_bytes="$(printf '%s' "${RUN_OUTPUT}" | wc -c)"
    if [ "${output_bytes}" -gt "${output_limit}" ]; then
        RUN_CODE=125
        RUN_OUTPUT="$(printf '%s' "${RUN_OUTPUT}" | head -c "${output_limit}")"$'\n''ERROR: output limit exceeded'
    fi
}

# --- Чтение SSH_ORIGINAL_COMMAND ---
# В режиме forced command sshd передаёт команду через эту переменную.
# Если wrapper вызван напрямую (тесты), используем аргументы.
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    set -- ${SSH_ORIGINAL_COMMAND}
fi

[ $# -ge 1 ] || die "Usage: broker-wrapper.sh <tool> [param=value...] [--dry-run]"

TOOL_NAME="$1"
shift

# Имя инструмента и аргументы имеют закрытый синтаксис. Значения затем
# дополнительно проверяются по type/allowed_values из tools.yaml.
[[ "${TOOL_NAME}" =~ ^[a-z][a-z0-9_]*$ ]] || die "Invalid tool name"

for arg in "$@"; do
    if [ "${arg}" = "--dry-run" ]; then
        continue
    fi
    if [[ "${arg}" != *=* ]]; then
        die "Invalid argument format: ${arg}"
    fi
    key="${arg%%=*}"
    val="${arg#*=}"
    [[ "${key}" =~ ^[a-z][a-z0-9_]*$ ]] || die "Invalid parameter name"
    [ -n "${val}" ] || die "Empty parameter value: ${key}"
    [[ "${val}" =~ ^[A-Za-z0-9_.:@%+,-]+$ ]] \
        || die "Rejected: parameter contains forbidden characters"
done

# --- Dry-run флаг ---
DRY_RUN=false
for arg in "$@"; do
    if [ "${arg}" = "--dry-run" ]; then
        DRY_RUN=true
        break
    fi
done

# --- Чтение реестра через Python ---
[ -f "${TOOLS_FILE}" ] || die "tools.yaml not found: ${TOOLS_FILE}"
command -v python3 >/dev/null 2>&1 || die "python3 required"

read_tool_field() {
    local field="$1"
    # Remove leading dot if present
    field="${field#.}"
    python3 -c "
import yaml, sys, json
with open('${TOOLS_FILE}') as f:
    data = yaml.safe_load(f)
tools = data.get('tools', [])
for t in tools:
    if t.get('name') == '${TOOL_NAME}':
        val = t.get('${field}')
        if val is None:
            print('__NULL__')
        elif isinstance(val, (list, dict)):
            print('__NULL__')
        else:
            print(str(val))
        sys.exit(0)
print('__NOTFOUND__')
sys.exit(0)
" 2>/dev/null
}

read_tool_params() {
    python3 -c "
import yaml, sys, json
with open('${TOOLS_FILE}') as f:
    data = yaml.safe_load(f)
for t in data.get('tools', []):
    if t.get('name') == '${TOOL_NAME}':
        params = t.get('params', {})
        print(json.dumps(params))
        sys.exit(0)
print('{}')
" 2>/dev/null || echo "{}"
}

read_tool_secrets_list() {
    python3 -c "
import yaml, sys, json
with open('${TOOLS_FILE}') as f:
    data = yaml.safe_load(f)
for t in data.get('tools', []):
    if t.get('name') == '${TOOL_NAME}':
        secrets = t.get('secrets', [])
        print(json.dumps(secrets if isinstance(secrets, list) else []))
        sys.exit(0)
print('[]')
" 2>/dev/null || echo "[]"
}

read_param_field() {
    local param="$1" field="$2"
    python3 -c "
import yaml
with open('${TOOLS_FILE}') as f:
    data = yaml.safe_load(f)
for tool in data.get('tools', []):
    if tool.get('name') == '${TOOL_NAME}':
        value = tool.get('params', {}).get('${param}', {}).get('${field}')
        if isinstance(value, list):
            print('\n'.join(str(item) for item in value))
        elif value is not None:
            print(value)
        break
" 2>/dev/null
}

TOOL_EXECUTE=$(read_tool_field '.execute')
TOOL_VERIFY=$(read_tool_field '.verify')
TOOL_ROLLBACK=$(read_tool_field '.rollback')
TOOL_RISK=$(read_tool_field '.risk')

if [ "${TOOL_EXECUTE}" = "__NOTFOUND__" ]; then
    die "Unknown tool: ${TOOL_NAME}"
fi

# --- Чтение описания параметров из YAML ---
PARAMS_DEF=$(read_tool_params)
SECRETS_LIST=$(read_tool_secrets_list)

# --- Парсинг и валидация параметров через Python ---
# Вывод JSON: {"init": {...}, "required": [...], "known": [...]}
PARSE_JSON=$(python3 -c "
import json, sys
params = json.loads('${PARAMS_DEF}')
init = {}
required = []
known = list(params.keys())
for name, cfg in params.items():
    if cfg.get('required') is True:
        required.append(name)
    if 'default' in cfg:
        init[name] = str(cfg['default'])
    elif cfg.get('required') is True:
        init[name] = '__REQUIRED__'
result = json.dumps({'init': init, 'required': required, 'known': known})
sys.stdout.write(result)
" 2>/dev/null)

# Извлекаем known, required, init через eval безопасно
KNOWN_PARAMS=$(python3 -c "
import json, sys
data = json.loads('${PARSE_JSON}')
print(' '.join(data.get('known', [])))
" 2>/dev/null)

REQUIRED_PARAMS=$(python3 -c "
import json, sys
data = json.loads('${PARSE_JSON}')
print(' '.join(data.get('required', [])))
" 2>/dev/null)

# Инициализация PARAMS через eval (обходит pipe+subshell проблему declare -A)
declare -A PARAMS
if [ -n "${PARSE_JSON}" ]; then
    eval "$(python3 -c "
import json, sys, shlex
data = json.loads('${PARSE_JSON}')
init = data.get('init', {})
for name, val in init.items():
    safe_val = shlex.quote(str(val))
    print('PARAMS[\"' + name + '\"]=' + safe_val)
" 2>/dev/null || echo "")"
fi

# --- Обработка переданных аргументов ---
for arg in "$@"; do
    [ "${arg}" = "--dry-run" ] && continue
    key="${arg%%=*}"
    val="${arg#*=}"

    # Проверка: параметр известен?
    found=false
    for kp in ${KNOWN_PARAMS:-}; do
        [ "${kp}" = "${key}" ] && found=true && break
    done
    if [ "${found}" = false ]; then
        die "Unknown parameter: ${key}"
    fi
    PARAMS["${key}"]="${val}"
done

# --- Проверка required-параметров ---
for rparam in ${REQUIRED_PARAMS:-}; do
    [ -z "${rparam}" ] && continue
    val="${PARAMS[${rparam}]:-}"
    if [ "${val}" = "__REQUIRED__" ] || [ -z "${val}" ]; then
        die "Required parameter missing: ${rparam}"
    fi
done

# --- Проверка типов и закрытых списков значений ---
for key in "${!PARAMS[@]}"; do
    val="${PARAMS[$key]}"
    param_type="$(read_param_field "${key}" type)"
    if [ "${param_type}" = "integer" ] && ! [[ "${val}" =~ ^[0-9]+$ ]]; then
        die "Parameter ${key} must be an integer"
    fi
    if [ "${param_type}" = "integer" ]; then
        min_value="$(read_param_field "${key}" min)"
        max_value="$(read_param_field "${key}" max)"
        if [ -n "${min_value}" ] && [ "${val}" -lt "${min_value}" ]; then
            die "Parameter ${key} must be at least ${min_value}"
        fi
        if [ -n "${max_value}" ] && [ "${val}" -gt "${max_value}" ]; then
            die "Parameter ${key} must be at most ${max_value}"
        fi
    fi

    allowed_values="$(read_param_field "${key}" allowed_values)"
    if [ -n "${allowed_values}" ]; then
        allowed=false
        while IFS= read -r item; do
            [ "${val}" = "${item}" ] && allowed=true && break
        done <<< "${allowed_values}"
        [ "${allowed}" = true ] || die "Parameter ${key} has a forbidden value"
    fi
done

# --- Подстановка параметров в команду ---
EXECUTE_CMD="${TOOL_EXECUTE}"
VERIFY_CMD="${TOOL_VERIFY}"
ROLLBACK_CMD="${TOOL_ROLLBACK}"
CHECK_CMD=$(read_tool_field '.check')

for key in "${!PARAMS[@]}"; do
    val="${PARAMS[$key]}"
    EXECUTE_CMD="${EXECUTE_CMD//\{\{$key\}\}/${val}}"
    VERIFY_CMD="${VERIFY_CMD//\{\{$key\}\}/${val}}"
    ROLLBACK_CMD="${ROLLBACK_CMD//\{\{$key\}\}/${val}}"
    CHECK_CMD="${CHECK_CMD//\{\{$key\}\}/${val}}"
done

# --- Подстановка секретов (на хосте, ДО вывода куда-либо) ---
SECRET_SUBSTITUTED=false
if [ "${SECRETS_LIST}" != "[]" ] && [ -n "${SECRETS_LIST}" ]; then
    mapfile -t SECRET_LINES < <(echo "${SECRETS_LIST}" | python3 -c "
import json, sys, os
secrets = json.loads(sys.stdin.read())
for s in secrets:
    secret_file = '${SECRETS_DIR}/' + s
    if os.path.isfile(secret_file):
        with open(secret_file) as f:
            val = f.read().rstrip(chr(10))
        print(s + '=' + val)
    else:
        print(s + '=__MISSING__')
        sys.exit(1)
" 2>/dev/null)
    for secret_line in "${SECRET_LINES[@]}"; do
        IFS='=' read -r sname sval <<< "${secret_line}"
        if [ "${sval}" = "__MISSING__" ]; then
            die "Secret not found: ${sname}"
        fi
        # Подстановка во все команды
        EXECUTE_CMD="${EXECUTE_CMD//\{\{secret:${sname}\}\}/${sval}}"
        VERIFY_CMD="${VERIFY_CMD//\{\{secret:${sname}\}\}/${sval}}"
        ROLLBACK_CMD="${ROLLBACK_CMD//\{\{secret:${sname}\}\}/${sval}}"
        CHECK_CMD="${CHECK_CMD//\{\{secret:${sname}\}\}/${sval}}"
        SECRET_SUBSTITUTED=true
    done
fi

# --- Формирование параметров для журнала (секреты заменены на ***) ---
LOG_PARAMS=""
for key in "${!PARAMS[@]}"; do
    LOG_PARAMS="${LOG_PARAMS} ${key}=$(sanitize_log_param "${PARAMS[$key]}")"
done
LOG_PARAMS="$(echo "${LOG_PARAMS}" | xargs)"

# --- Уровень C: полное отключение ---
if [ "${TOOL_RISK}" = "C" ]; then
    die "Level C tools are not implemented. Explicit user action required on host."
fi

# --- Dry-run (секреты уже подставлены, НО не выводим команду если есть секреты) ---
START_TS=$(date +%s)
echo "TOOL: ${TOOL_NAME} [${TOOL_RISK}]"
[ -n "${LOG_PARAMS}" ] && echo "PARAMS: ${LOG_PARAMS}"
[ "${DRY_RUN}" = "true" ] && echo "MODE: DRY-RUN"

if [ "${DRY_RUN}" = "true" ]; then
    if [ "${SECRET_SUBSTITUTED}" = "true" ]; then
        echo "DRY-RUN: Would execute (secrets masked)"
        echo "DRY-RUN: Would verify (secrets masked)"
    else
        echo "DRY-RUN: Would execute: ${EXECUTE_CMD}"
        [ "${VERIFY_CMD}" != "__NULL__" ] && [ -n "${VERIFY_CMD}" ] && echo "DRY-RUN: Would verify: ${VERIFY_CMD}"
    fi
    if [ "${ROLLBACK_CMD}" != "__NULL__" ] && [ -n "${ROLLBACK_CMD}" ]; then
        echo "DRY-RUN: Rollback available"
    fi
    audit_required "${TOOL_NAME}" "${LOG_PARAMS}" 0 0 "DRY_RUN"
    exit 0
fi

# --- Pre-check ---
audit_required "${TOOL_NAME}" "${LOG_PARAMS}" 0 0 "STARTED"
if [ -n "${CHECK_CMD}" ] && [ "${CHECK_CMD}" != "__NULL__" ]; then
    run_bounded "${CHECK_TIMEOUT_SEC}" "${CHECK_CMD}" "${MAX_DIAG_BYTES}"
    CHECK_OUTPUT="${RUN_OUTPUT}"
    CHECK_CODE="${RUN_CODE}"
    if [ "${CHECK_CODE}" -ne 0 ]; then
        audit_required "${TOOL_NAME}" "${LOG_PARAMS}" "${CHECK_CODE}" 0 "PRECHECK_FAILED"
        echo "ERROR: pre-check failed" >&2
        exit "${CHECK_CODE}"
    fi
fi

# --- Выполнение ---
run_bounded "${TIMEOUT_SEC}" "${EXECUTE_CMD}" "${MAX_OUTPUT_BYTES}"
OUTPUT="${RUN_OUTPUT}"
EXIT_CODE="${RUN_CODE}"

DURATION=$(( $(date +%s) - START_TS ))

# --- Verify ---
VERIFY_FAILED=false
if [ ${EXIT_CODE} -eq 0 ] && [ "${VERIFY_CMD}" != "__NULL__" ] && [ -n "${VERIFY_CMD}" ]; then
    run_bounded "${CHECK_TIMEOUT_SEC}" "${VERIFY_CMD}" "${MAX_DIAG_BYTES}"
    VERIFY_OUTPUT="${RUN_OUTPUT}"
    VERIFY_CODE="${RUN_CODE}"
    if [ ${VERIFY_CODE} -ne 0 ]; then
        VERIFY_FAILED=true
        audit_required "${TOOL_NAME}" "${LOG_PARAMS}" "${VERIFY_CODE}" "${DURATION}" "VERIFY_FAILED"
        echo "WARN: execute OK but verify failed"

        # Rollback
        if [ "${ROLLBACK_CMD}" != "__NULL__" ] && [ -n "${ROLLBACK_CMD}" ]; then
            echo "ROLLBACK: executing..."
            run_bounded "${TIMEOUT_SEC}" "${ROLLBACK_CMD}" "${MAX_DIAG_BYTES}"
            RB_OUTPUT="${RUN_OUTPUT}"
            RB_CODE="${RUN_CODE}"
            audit_required "${TOOL_NAME}" "${LOG_PARAMS}" "${RB_CODE}" "${DURATION}" "ROLLBACK"
            echo "ROLLBACK: exit code ${RB_CODE}"
        fi
        exit ${VERIFY_CODE}
    fi
fi

# --- Успех ---
echo "${OUTPUT}"
if [ "${EXIT_CODE}" -eq 0 ]; then
    FINAL_STATUS="OK"
else
    FINAL_STATUS="EXECUTE_FAILED"
fi
audit_required "${TOOL_NAME}" "${LOG_PARAMS}" "${EXIT_CODE}" "${DURATION}" "${FINAL_STATUS}"
exit ${EXIT_CODE}
