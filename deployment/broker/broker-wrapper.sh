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
LOG_DIR="${OPENHANDS_BROKER_LOG_DIR:-/var/log/openhands-broker}"
ACTIONS_LOG="${LOG_DIR}/actions.log"
ERROR_LOG="${LOG_DIR}/error.log"
TIMEOUT_SEC=120

# --- Блокировка (simple flock, optional) ---
flock -n /tmp/.openhands-broker-wrapper.lock -c "" 2>/dev/null || :

# --- Утилиты ---
log_action_json() {
    local tool="$1" params="$2" exit_code="$3" duration="$4" status="$5"
    python3 -c "
import json, sys
record = {
    'ts': '$(date --utc +"%Y-%m-%dT%H:%M:%SZ")',
    'tool': $(python3 -c "import json; print(json.dumps('$tool'))"),
    'params': $(python3 -c "import json; print(json.dumps('$params'))"),
    'exit_code': ${exit_code},
    'duration_sec': ${duration},
    'status': $(python3 -c "import json; print(json.dumps('$status'))")
}
sys.stdout.write(json.dumps(record) + chr(10))
" >> "${ACTIONS_LOG}" 2>/dev/null || true
}

log_error() {
    local ts
    ts="$(date --utc +"%Y-%m-%dT%H:%M:%SZ")"
    echo "${ts} $*" >> "${ERROR_LOG}" 2>/dev/null || true
}

die() {
    echo "ERROR: $*" >&2
    log_error "$*"
    exit 1
}

sanitize_log_param() {
    local val="$1"
    # Заменяем любые подозрительные символы
    echo "${val}" | tr -d '[:cntrl:]' | head -c 200
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

# --- Защита от injection: базовые паттерны ---
for arg in "$@"; do
    if [ "${arg}" = "--dry-run" ]; then
        continue
    fi
    # Проверяем только param=value
    if [[ "${arg}" != *=* ]]; then
        die "Invalid argument format: ${arg}"
    fi
    # Injection-паттерны
    if echo "${arg}" | grep -qE '[;&$()`|]'; then
        die "Rejected: argument contains shell metacharacters"
    fi
    if echo "${arg}" | grep -qE '`'; then
        die "Rejected: argument contains backtick"
    fi
    if echo "${arg}" | grep -qE '\$\('; then
        die "Rejected: argument contains $()"
    fi
    if echo "${arg}" | grep -qE '\.\./'; then
        die "Rejected: argument contains path traversal"
    fi
    if echo "${arg}" | grep -qE '^\s*/'; then
        die "Rejected: argument starts with absolute path"
    fi
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
    echo "${SECRETS_LIST}" | python3 -c "
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
" 2>/dev/null | while IFS='=' read -r sname sval; do
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
    log_action_json "${TOOL_NAME}" "${LOG_PARAMS}" 0 0 "DRY-RUN"
    exit 0
fi

# --- Pre-check ---
if [ -n "${CHECK_CMD}" ] && [ "${CHECK_CMD}" != "__NULL__" ]; then
    set +e
    CHECK_OUTPUT=$(timeout 10 bash -c "${CHECK_CMD}" 2>&1)
    CHECK_CODE=$?
    set -e
fi

# --- Выполнение ---
set +e
OUTPUT=$(timeout "${TIMEOUT_SEC}" bash -c "${EXECUTE_CMD}" 2>&1)
EXIT_CODE=$?
set -e

DURATION=$(( $(date +%s) - START_TS ))

# --- Verify ---
VERIFY_FAILED=false
if [ ${EXIT_CODE} -eq 0 ] && [ "${VERIFY_CMD}" != "__NULL__" ] && [ -n "${VERIFY_CMD}" ]; then
    set +e
    VERIFY_OUTPUT=$(timeout 10 bash -c "${VERIFY_CMD}" 2>&1)
    VERIFY_CODE=$?
    set -e
    if [ ${VERIFY_CODE} -ne 0 ]; then
        VERIFY_FAILED=true
        log_action_json "${TOOL_NAME}" "${LOG_PARAMS}" "${EXIT_CODE}" "${DURATION}" "VERIFY_FAILED"
        log_error "${TOOL_NAME}: execute OK but verify failed"
        echo "WARN: execute OK but verify failed"

        # Rollback
        if [ "${ROLLBACK_CMD}" != "__NULL__" ] && [ -n "${ROLLBACK_CMD}" ]; then
            echo "ROLLBACK: executing..."
            set +e
            RB_OUTPUT=$(timeout "${TIMEOUT_SEC}" bash -c "${ROLLBACK_CMD}" 2>&1)
            RB_CODE=$?
            set -e
            log_action_json "${TOOL_NAME}" "${LOG_PARAMS}" "${RB_CODE}" "${DURATION}" "ROLLBACK"
            echo "ROLLBACK: exit code ${RB_CODE}"
        fi
        exit ${VERIFY_CODE}
    fi
fi

# --- Успех ---
echo "${OUTPUT}"
log_action_json "${TOOL_NAME}" "${LOG_PARAMS}" "${EXIT_CODE}" "${DURATION}" "OK"
exit ${EXIT_CODE}
