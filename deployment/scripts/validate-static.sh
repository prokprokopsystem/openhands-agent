#!/usr/bin/bash
# OpenHands Agent Canvas — статическая валидация
# Работает на чистом checkout без /srv/openhands-agent/secrets/.env
# Завершается с ненулевым кодом при любой ошибке.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${PROJECT_ROOT}"

PASSED=0
FAILED=0
VALIDATION_TMP=$(mktemp -d)
COMPOSE_RENDERED=false
RENDERED_COMPOSE_JSON=""

cleanup_validation() {
    rm -rf "${VALIDATION_TMP}"
}

trap cleanup_validation EXIT

pass() { printf '  [OK] %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAILED=$((FAILED + 1)); }

echo "=== Static validation ==="
echo ""

# ── 1. Shell syntax ──
echo "--- Shell syntax ---"
for f in deployment/scripts/*.sh deployment/network/*.sh; do
    bash -n "$f" 2>/dev/null && pass "$f" || fail "$f: bash -n"
done

# ── 2. Executable bits ──
echo ""
echo "--- Executable bits ---"
for f in deployment/scripts/*.sh deployment/network/*.sh; do
    [ -x "$f" ] && pass "$f" || fail "$f: NOT executable"
done

# ── 3. Shebang ──
echo ""
echo "--- Shebang consistency ---"
for f in deployment/scripts/*.sh deployment/network/*.sh; do
    head -1 "$f" | grep -qE '^#!/usr/bin/(env bash|bash)$' && pass "$f: shebang" || fail "$f: wrong shebang"
done

# ── 4. Compose: no restart ──
echo ""
echo "--- Compose invariants ---"
grep -q 'restart:.*"no"' deployment/compose.yaml && pass "restart: no" || fail "restart: должно быть \"no\""
grep -q 'docker.sock' deployment/compose.yaml && fail "docker.sock найден в compose" || pass "docker.sock отсутствует"
grep -q 'test-workspace' deployment/compose.yaml && pass "test-workspace : не общий workspace" || fail "нет test-workspace"
grep -q 'enable_ipv6: false' deployment/compose.yaml && pass "IPv6 отключён : сеть" || fail "IPv6 не отключён в сети"
grep -q 'disable_ipv6' deployment/compose.yaml && pass "IPv6 отключён : sysctl" || fail "IPv6 sysctl отсутствует"
grep -q 'sha256:fc24163754bee' deployment/broker-client/Dockerfile && pass "digest зафиксирован" || fail "digest отсутствует"

# ── 5. Systemd invariants ──
echo ""
echo "--- Systemd invariants ---"
SVC="deployment/systemd/openhands-agent.service"
grep -q 'ExecStartPre=.*validate-runtime.sh' "${SVC}" && pass "ExecStartPre: validate-runtime" || fail "ExecStartPre: нет validate-runtime"
grep -q 'ExecStartPre=.*compose.*create' "${SVC}" && pass "ExecStartPre: compose create" || fail "ExecStartPre: нет compose create"
grep -q 'ExecStartPre=.*apply-egress-rules' "${SVC}" && pass "ExecStartPre: apply-egress-rules" || fail "ExecStartPre: нет apply-egress-rules"
grep -q 'ExecStart=.*run-supervised' "${SVC}" && pass "ExecStart: run-supervised" || fail "ExecStart: не run-supervised"
grep -q '^KillMode=mixed$' "${SVC}" && pass "KillMode=mixed" || fail "KillMode должен быть mixed"
grep -q '^ExecStop=.*docker compose.*down' "${SVC}" && fail "ExecStop: прямой compose down запрещён" || pass "ExecStop: прямого compose down нет"
EXEC_STOP_POST=$(grep '^ExecStopPost=' "${SVC}" || true)
if grep -q 'docker compose.*down --remove-orphans' <<<"${EXEC_STOP_POST}"; then
    pass "ExecStopPost: compose down --remove-orphans"
else
    fail "ExecStopPost: нет compose down --remove-orphans"
fi
if grep -q 'remove-egress-rules.sh' <<<"${EXEC_STOP_POST}" &&
    [[ "${EXEC_STOP_POST}" == *"docker compose"*"remove-egress-rules.sh"* ]]; then
    pass "ExecStopPost: firewall удаляется после Compose"
else
    fail "ExecStopPost: неверный порядок Compose/firewall"
fi
grep -q 'down --remove-orphans && .*remove-egress-rules.sh' <<<"${EXEC_STOP_POST}" \
    && pass "ExecStopPost: ошибка Compose сохраняет firewall" \
    || fail "ExecStopPost: firewall может сняться после ошибки Compose"

# ── 6. No direct docker compose up -d ──
echo ""
echo "--- No direct compose launch ---"
grep -r 'docker compose up' deployment/scripts/start.sh 2>/dev/null && fail "start.sh содержит docker compose up" || pass "start.sh: без docker compose up"
grep -r 'systemctl start' deployment/scripts/start.sh 2>/dev/null && pass "start.sh: systemctl start" || fail "start.sh: нет systemctl start"
grep -r 'systemctl stop' deployment/scripts/stop.sh 2>/dev/null && pass "stop.sh: systemctl stop" || fail "stop.sh: нет systemctl stop"

# ── 7. Purge invariants ──
echo ""
echo "--- Purge invariants ---"
grep -q '\${1:-}' deployment/scripts/purge-test.sh && pass "purge: \${1:-}" || fail "purge: нет \${1:-}"
grep -q 'systemctl stop' deployment/scripts/purge-test.sh && pass "purge: systemctl stop" || fail "purge: нет systemctl stop"
grep -q 'systemctl disable' deployment/scripts/purge-test.sh && pass "purge: systemctl disable" || fail "purge: нет systemctl disable"

# ── 8. Firewall invariants ──
echo ""
echo "--- Firewall invariants ---"
FW="deployment/network/apply-egress-rules.sh"
grep -q 'OPENHANDS-EGRESS' "${FW}" && pass "firewall: OPENHANDS-EGRESS" || fail "firewall: нет OPENHANDS-EGRESS"
grep -q 'OPENHANDS-INPUT' "${FW}" && pass "firewall: OPENHANDS-INPUT" || fail "firewall: нет OPENHANDS-INPUT"
grep -q 'ESTABLISHED,RELATED' "${FW}" && pass "firewall: ESTABLISHED,RELATED" || fail "firewall: нет ESTABLISHED,RELATED"
grep -q '\-j DROP' "${FW}" && pass "firewall: финальный DROP" || fail "firewall: нет финального DROP"
grep -q '95.217.239.148' "${FW}" && pass "firewall: VPS заблокирован" || fail "firewall: VPS не заблокирован"

# ── 9. Secrets ──
echo ""
echo "--- Secrets ---"
SECRETS=$(grep -rn 'ghp_\|sk-or-\|sk-ant\|sk-proj\|Bearer [A-Za-z0-9]\{10\}' --include="*.md" --include="*.yaml" --include="*.sh" --include="*.service" . 2>/dev/null | grep -v '.git/\|.example\|your-\|openssl\|placeholder\|p...ab' || true)
[ -z "${SECRETS}" ] && pass "Секреты не найдены" || fail "Возможные секреты: ${SECRETS}"

# ── 10. No LLM env vars ──
echo ""
echo "--- LLM env vars ---"
LLM=$(grep -rn 'LLM_API_KEY\|LLM_MODEL\|LLM_BASE_URL' --include="*.md" --include="*.yaml" --include="*.sh" --include="*.example" --include="*.service" . 2>/dev/null | grep -v 'не являются\|НЕ через\|через WebUI\|настраиваются\|не переменные\|запрещ\|\.git/\|LLM_API_KEY/LLM_MODEL') || true
[ -z "${LLM}" ] && pass "LLM_API_KEY/LLM_MODEL/LLM_BASE_URL: 0 в runtime" || fail "LLM-переменные: ${LLM}"

# ── 11. Docker compose config from a clean checkout ──
echo ""
echo "--- docker compose config ---"
if docker compose version >/dev/null 2>&1; then
    COMPOSE_TMP=$(mktemp -d "${VALIDATION_TMP}/compose.XXXXXX")
    cp deployment/compose.yaml "${COMPOSE_TMP}/compose.yaml"
    printf '%s\n' 'LOCAL_BACKEND_API_KEY=placeholder-static-check-only' > "${COMPOSE_TMP}/test.env"
    sed -i "s|/srv/openhands-agent/secrets/.env|${COMPOSE_TMP}/test.env|" "${COMPOSE_TMP}/compose.yaml"
    RENDERED_COMPOSE_JSON="${COMPOSE_TMP}/rendered-compose.json"

    if docker compose -f "${COMPOSE_TMP}/compose.yaml" config --format json > "${RENDERED_COMPOSE_JSON}" 2>/dev/null; then
        COMPOSE_RENDERED=true
        pass "docker compose config: clean checkout with controlled env_file substitution"
    else
        fail "docker compose config: clean checkout"
    fi
else
    echo "  [SKIP] docker compose недоступен"
fi

# ── 12. systemd-analyze ──
echo ""
echo "--- systemd-analyze verify ---"
if command -v systemd-analyze >/dev/null 2>&1; then
    SYSTEMD_TMP=$(mktemp -d "${VALIDATION_TMP}/systemd.XXXXXX")
    SYSTEMD_TEST_UNIT="${SYSTEMD_TMP}/openhands-agent.service"
    sed "s|/srv/openhands-agent|${PROJECT_ROOT}|g" "${SVC}" > "${SYSTEMD_TEST_UNIT}"
    set +e
    RESULT=$(systemd-analyze verify "${SYSTEMD_TEST_UNIT}" 2>&1)
    SYSTEMD_VERIFY_RC=$?
    set -e
    REAL=$(
        printf '%s\n' "${RESULT}" \
            | grep -vE '^.*Failed to create .*: Unit (docker\.service|wg-quick@wg0\.service) not found\.$' \
            || true
    )
    if [ "${SYSTEMD_VERIFY_RC}" -eq 0 ] || [ -z "${REAL}" ]; then
        pass "systemd-analyze verify: checkout paths valid; only external units may be absent"
    else
        fail "systemd-analyze: ошибки"
        echo "${RESULT}"
    fi
else
    echo "  [SKIP] systemd-analyze недоступен"
fi

# ── 13. Docs: no manual compose launch ──
echo ""
echo "--- Docs: no manual compose ---"
SSH_SESSION_LINE=$(grep -n '^ssh mini-server$' deployment/README.md | head -1 | cut -d: -f1 || true)
KEY_SECTION_LINE=$(grep -n '^### 2\. Создание ключа$' deployment/README.md | head -1 | cut -d: -f1 || true)
if [ -n "${SSH_SESSION_LINE}" ] && [ -n "${KEY_SECTION_LINE}" ] && [ "${SSH_SESSION_LINE}" -lt "${KEY_SECTION_LINE}" ]; then
    pass "README: постоянная SSH-сессия открывается перед созданием ключа"
else
    fail "README: нет явного ssh mini-server перед созданием ключа"
fi
grep -q '^Все дальнейшие команды до конца инструкции выполняются внутри этой SSH-сессии на mini-server\.$' deployment/README.md \
    && pass "README: дальнейшие команды явно относятся к mini-server" \
    || fail "README: нет пояснения о постоянной SSH-сессии"
grep -q '^exit$' deployment/README.md \
    && pass "README: SSH-сессия завершается командой exit" \
    || fail "README: нет exit в конце инструкции"
grep -r 'docker compose up' deployment/README.md 2>/dev/null | grep -v 'запрещ\|ЗАПРЕЩ\|forbidden' >/dev/null && fail "README: docker compose up" || pass "README: без docker compose up"
grep -r 'systemctl start' deployment/README.md 2>/dev/null && pass "README: systemctl start" || fail "README: нет systemctl start"
grep -q 'mini-server:~/openhands-agent-stage/' deployment/README.md && pass "README: копирование через домашний staging" || fail "README: нет домашнего staging"
grep -q 'sudo mkdir -p /srv/openhands-agent' deployment/README.md && pass "README: /srv создаётся через sudo" || fail "README: /srv не создаётся через sudo"
grep -q 'sudo cp -a ~/openhands-agent-stage/deployment /srv/openhands-agent/' deployment/README.md && pass "README: staging копируется без deployment/deployment" || fail "README: недетерминированное копирование deployment"
grep -q "ssh mini-server 'sudo /usr/bin/bash /srv/openhands-agent/deployment/scripts/prepare.sh'" deployment/README.md && pass "README: prepare.sh запускается на mini-server" || fail "README: prepare.sh запускается не через mini-server"
grep -Eq 'scp .*mini-server:/srv' deployment/README.md && fail "README: прямой scp в /srv запрещён" || pass "README: нет прямого scp в /srv"

# ── 14. Docs: no key entry screen claim ──
echo ""
echo "--- Docs: no manual key screen ---"
grep -ri 'ввести.*LOCAL_BACKEND_API_KEY\|экран.*ввода.*ключа\|enter.*API key' deployment/README.md docs/Решения.md docs/Состояние.md 2>/dev/null && fail "Документация: экран ввода ключа" || pass "Документация: без экрана ввода ключа"

# ── 15. Healthcheck from rendered Compose ──
echo ""
echo "--- Rendered healthcheck ---"
if ! ${COMPOSE_RENDERED}; then
    fail "healthcheck: rendered Compose недоступен"
else
    if python3 - "${RENDERED_COMPOSE_JSON}" <<'PY'
import json
import shlex
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    rendered = json.load(stream)

test = rendered["services"]["openhands"]["healthcheck"]["test"]
if not isinstance(test, list) or len(test) != 2 or test[0] != "CMD-SHELL":
    raise SystemExit("healthcheck.test was not rendered as [CMD-SHELL, command]")

command = test[1]
canvas_position = command.find("/canvas")
port_18000_position = command.find("18000")
port_18001_position = command.find("18001")
if min(canvas_position, port_18000_position, port_18001_position) < 0:
    raise SystemExit("rendered healthcheck is missing /canvas, 18000 or 18001")
if canvas_position > min(port_18000_position, port_18001_position):
    raise SystemExit("/canvas must be checked before backend TCP listeners")

tokens = shlex.split(command)
python_index = tokens.index("python3")
if tokens[python_index + 1] != "-c":
    raise SystemExit("rendered healthcheck lost python3 -c")
compile(tokens[python_index + 2], "<rendered-healthcheck>", "exec")
PY
    then
        pass "healthcheck: rendered quoting, /canvas order, ports 18000/18001 and Python syntax"
    else
        fail "healthcheck: rendered command validation"
    fi
fi

# ── 16. Supervisor: real behavioral tests ──
echo ""
echo "--- Supervisor behavioral tests ---"
SUPERVISOR_TEST_ROOT=$(mktemp -d "${VALIDATION_TMP}/supervisor.XXXXXX")
MOCK_DOCKER="${SUPERVISOR_TEST_ROOT}/mock-docker"
MOCK_WATCHDOG="${SUPERVISOR_TEST_ROOT}/mock-watchdog"

cat > "${MOCK_DOCKER}" <<'EOF'
#!/usr/bin/bash
set -euo pipefail

if [ "$1" = "compose" ] && [ "${4:-}" = "up" ]; then
    printf '%s\n' "$$" > "${MOCK_PID_DIR}/compose.pid"
    exec python3 -c 'import os, sys, time; time.sleep(float(os.environ["MOCK_COMPOSE_DELAY"])); sys.exit(int(os.environ["MOCK_COMPOSE_RC"]))'
elif [ "$1" = "compose" ] && [ "${4:-}" = "down" ]; then
    : > "${MOCK_PID_DIR}/compose-down.called"
    if [ -f "${MOCK_PID_DIR}/compose.pid" ]; then
        kill -TERM "$(cat "${MOCK_PID_DIR}/compose.pid")" 2>/dev/null || true
    fi
    exit 0
fi

exit 2
EOF
chmod +x "${MOCK_DOCKER}"

cat > "${MOCK_WATCHDOG}" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
printf '%s\n' "$$" > "${MOCK_PID_DIR}/watchdog.pid"
exec python3 -c 'import os, sys, time; time.sleep(float(os.environ["MOCK_WATCHDOG_DELAY"])); sys.exit(int(os.environ["MOCK_WATCHDOG_RC"]))'
EOF
chmod +x "${MOCK_WATCHDOG}"

wait_for_pid_files() {
    local case_dir="$1"
    local attempt

    for attempt in $(seq 1 100); do
        if [ -s "${case_dir}/compose.pid" ] && [ -s "${case_dir}/watchdog.pid" ]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

wait_for_process_exit() {
    local pid="$1"
    local attempt

    for attempt in $(seq 1 200); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

mock_children_stopped() {
    local case_dir="$1"
    local child_pid

    for child_name in compose watchdog; do
        [ -s "${case_dir}/${child_name}.pid" ] || return 1
        child_pid=$(cat "${case_dir}/${child_name}.pid")
        if kill -0 "${child_pid}" 2>/dev/null; then
            return 1
        fi
    done
}

collected_once() {
    local log_file="$1"
    [ "$(grep -c 'compose collected exit=' "${log_file}" || true)" -eq 1 ] &&
        [ "$(grep -c 'watchdog collected exit=' "${log_file}" || true)" -eq 1 ]
}

run_failure_case() {
    local name="$1"
    local compose_rc="$2"
    local compose_delay="$3"
    local watchdog_rc="$4"
    local watchdog_delay="$5"
    local expected_compose_log="$6"
    local expected_watchdog_log="$7"
    local expect_compose_down="$8"
    local case_dir
    local supervisor_pid
    local supervisor_rc=0

    case_dir=$(mktemp -d "${SUPERVISOR_TEST_ROOT}/${name}.XXXXXX")
    printf '%s\n' 'services: {}' > "${case_dir}/compose.yaml"

    MOCK_PID_DIR="${case_dir}" \
    MOCK_COMPOSE_RC="${compose_rc}" \
    MOCK_COMPOSE_DELAY="${compose_delay}" \
    MOCK_WATCHDOG_RC="${watchdog_rc}" \
    MOCK_WATCHDOG_DELAY="${watchdog_delay}" \
    COMPOSE_FILE="${case_dir}/compose.yaml" \
    WATCHDOG="${MOCK_WATCHDOG}" \
    DOCKER_BIN="${MOCK_DOCKER}" \
    SUPERVISOR_POLL_INTERVAL=0.05 \
    SUPERVISOR_TERM_TIMEOUT=2 \
        /usr/bin/bash deployment/scripts/run-supervised.sh > "${case_dir}/supervisor.log" 2>&1 &
    supervisor_pid=$!

    if ! wait_for_pid_files "${case_dir}"; then
        fail "${name}: mock PID files not created"
        kill -KILL "${supervisor_pid}" 2>/dev/null || true
        wait "${supervisor_pid}" 2>/dev/null || true
        return
    fi

    if ! wait_for_process_exit "${supervisor_pid}"; then
        fail "${name}: supervisor timed out"
        kill -TERM "${supervisor_pid}" 2>/dev/null || true
        sleep 0.2
        kill -KILL "${supervisor_pid}" 2>/dev/null || true
    fi

    set +e
    wait "${supervisor_pid}"
    supervisor_rc=$?
    set -e

    if [ "${supervisor_rc}" -ne 0 ] && [ "${supervisor_rc}" -ne 124 ]; then
        pass "${name}: supervisor non-zero (rc=${supervisor_rc})"
    else
        fail "${name}: supervisor rc=${supervisor_rc}, expected non-zero and not 124"
    fi

    if grep -q "${expected_compose_log}" "${case_dir}/supervisor.log" &&
        grep -q "${expected_watchdog_log}" "${case_dir}/supervisor.log"; then
        pass "${name}: both real exit codes collected"
    else
        fail "${name}: expected exit codes missing"
        sed -n '1,160p' "${case_dir}/supervisor.log"
    fi

    collected_once "${case_dir}/supervisor.log" \
        && pass "${name}: each PID waited exactly once" \
        || fail "${name}: PID collection count is not exactly one each"

    if [ "${expect_compose_down}" = "yes" ]; then
        [ -f "${case_dir}/compose-down.called" ] \
            && pass "${name}: compose down called" \
            || fail "${name}: compose down was not called"
    else
        [ ! -f "${case_dir}/compose-down.called" ] \
            && pass "${name}: compose down not needed" \
            || fail "${name}: unexpected compose down"
    fi

    mock_children_stopped "${case_dir}" \
        && pass "${name}: no mock child remains" \
        || fail "${name}: mock child still running"
}

# A — Compose 7, watchdog long-running.
run_failure_case "A-compose-7" 7 0.20 0 30 \
    'compose collected exit=7' 'watchdog collected exit=143' no

# B — Watchdog 8, Compose long-running.
run_failure_case "B-watchdog-8" 0 30 8 0.20 \
    'compose collected exit=143' 'watchdog collected exit=8' yes

# C — race: Compose 0 and watchdog 8.
run_failure_case "C-race-compose-0-watchdog-8" 0 0.20 8 0.20 \
    'compose collected exit=0' 'watchdog collected exit=8' no

# D — reverse race: Compose 7 and watchdog 0.
run_failure_case "D-race-compose-7-watchdog-0" 7 0.20 0 0.20 \
    'compose collected exit=7' 'watchdog collected exit=0' no

# E — unexpected Compose exit 0.
run_failure_case "E-compose-0" 0 0.20 0 30 \
    'compose collected exit=0' 'watchdog collected exit=143' no

# F — unexpected watchdog exit 0.
run_failure_case "F-watchdog-0" 0 30 0 0.20 \
    'compose collected exit=143' 'watchdog collected exit=0' yes

# G — real SIGTERM must produce exactly 0 and reap both children.
SIGTERM_DIR=$(mktemp -d "${SUPERVISOR_TEST_ROOT}/G-sigterm.XXXXXX")
printf '%s\n' 'services: {}' > "${SIGTERM_DIR}/compose.yaml"
RC_G=0

MOCK_PID_DIR="${SIGTERM_DIR}" \
MOCK_COMPOSE_RC=0 \
MOCK_COMPOSE_DELAY=30 \
MOCK_WATCHDOG_RC=0 \
MOCK_WATCHDOG_DELAY=30 \
COMPOSE_FILE="${SIGTERM_DIR}/compose.yaml" \
WATCHDOG="${MOCK_WATCHDOG}" \
DOCKER_BIN="${MOCK_DOCKER}" \
SUPERVISOR_POLL_INTERVAL=0.05 \
SUPERVISOR_TERM_TIMEOUT=2 \
    /usr/bin/bash deployment/scripts/run-supervised.sh > "${SIGTERM_DIR}/supervisor.log" 2>&1 &
SIGTERM_SUPERVISOR_PID=$!

if wait_for_pid_files "${SIGTERM_DIR}"; then
    kill -TERM "${SIGTERM_SUPERVISOR_PID}"
    if ! wait_for_process_exit "${SIGTERM_SUPERVISOR_PID}"; then
        fail "G-SIGTERM: supervisor timed out"
        kill -KILL "${SIGTERM_SUPERVISOR_PID}" 2>/dev/null || true
    fi
    set +e
    wait "${SIGTERM_SUPERVISOR_PID}"
    RC_G=$?
    set -e

    [ "${RC_G}" -eq 0 ] \
        && pass "G-SIGTERM: supervisor exit exactly 0" \
        || fail "G-SIGTERM: supervisor rc=${RC_G}, expected 0"
    collected_once "${SIGTERM_DIR}/supervisor.log" \
        && pass "G-SIGTERM: each PID waited exactly once" \
        || fail "G-SIGTERM: PID collection count is not exactly one each"
    if grep -q 'compose collected exit=143' "${SIGTERM_DIR}/supervisor.log" &&
        grep -q 'watchdog collected exit=143' "${SIGTERM_DIR}/supervisor.log"; then
        pass "G-SIGTERM: both child exit codes collected (compose=143, watchdog=143)"
    else
        fail "G-SIGTERM: expected child exit codes missing"
        sed -n '1,160p' "${SIGTERM_DIR}/supervisor.log"
    fi
    mock_children_stopped "${SIGTERM_DIR}" \
        && pass "G-SIGTERM: no mock child remains" \
        || fail "G-SIGTERM: mock child still running"
else
    fail "G-SIGTERM: mock PID files not created"
    kill -KILL "${SIGTERM_SUPERVISOR_PID}" 2>/dev/null || true
    wait "${SIGTERM_SUPERVISOR_PID}" 2>/dev/null || true
fi

# ── 17. Production watchdog SIGTERM/no-child test ──
echo ""
echo "--- Watchdog SIGTERM/no-child test ---"
WATCHDOG_TEST_DIR=$(mktemp -d "${VALIDATION_TMP}/watchdog.XXXXXX")
WATCHDOG_DOCKER="${WATCHDOG_TEST_DIR}/mock-docker"
cat > "${WATCHDOG_DOCKER}" <<'EOF'
#!/usr/bin/bash
set -euo pipefail

case "$1" in
    ps)
        printf '%s\n' 'openhands-agent'
        ;;
    inspect)
        printf '%s\n' 'healthy'
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "${WATCHDOG_DOCKER}"

WATCHDOG_RC=0
WATCHDOG_CHILD_PID=""
DOCKER_BIN="${WATCHDOG_DOCKER}" \
WATCHDOG_START_PERIOD=30 \
WATCHDOG_CHECK_INTERVAL=30 \
WATCHDOG_MAX_UNHEALTHY=3 \
    /usr/bin/bash deployment/scripts/health-watchdog.sh > "${WATCHDOG_TEST_DIR}/watchdog.log" 2>&1 &
WATCHDOG_TEST_PID=$!

for attempt in $(seq 1 100); do
    if [ -r "/proc/${WATCHDOG_TEST_PID}/task/${WATCHDOG_TEST_PID}/children" ]; then
        WATCHDOG_CHILD_PID=$(awk '{print $1}' "/proc/${WATCHDOG_TEST_PID}/task/${WATCHDOG_TEST_PID}/children")
        [ -n "${WATCHDOG_CHILD_PID}" ] && break
    fi
    sleep 0.05
done

if [ -n "${WATCHDOG_CHILD_PID}" ]; then
    pass "watchdog: managed sleep child detected (${WATCHDOG_CHILD_PID})"
    kill -TERM "${WATCHDOG_TEST_PID}"
    if ! wait_for_process_exit "${WATCHDOG_TEST_PID}"; then
        fail "watchdog: did not stop after SIGTERM"
        kill -KILL "${WATCHDOG_TEST_PID}" 2>/dev/null || true
    fi
    set +e
    wait "${WATCHDOG_TEST_PID}"
    WATCHDOG_RC=$?
    set -e
    [ "${WATCHDOG_RC}" -eq 0 ] \
        && pass "watchdog: SIGTERM exit 0" \
        || fail "watchdog: SIGTERM exit ${WATCHDOG_RC}, expected 0"
    if kill -0 "${WATCHDOG_CHILD_PID}" 2>/dev/null; then
        fail "watchdog: managed sleep ${WATCHDOG_CHILD_PID} still running"
        kill -KILL "${WATCHDOG_CHILD_PID}" 2>/dev/null || true
    else
        pass "watchdog: managed sleep reaped"
    fi
else
    fail "watchdog: managed sleep child not detected"
    kill -TERM "${WATCHDOG_TEST_PID}" 2>/dev/null || true
    wait "${WATCHDOG_TEST_PID}" 2>/dev/null || true
fi

# ── 18. stop.sh firewall verification ──
echo ""
echo "--- stop.sh firewall verification ---"
STOP_TEST_DIR=$(mktemp -d "${VALIDATION_TMP}/stop.XXXXXX")
STOP_SUDO="${STOP_TEST_DIR}/sudo"
STOP_DOCKER="${STOP_TEST_DIR}/docker"
cat > "${STOP_SUDO}" <<'EOF'
#!/usr/bin/bash
set -euo pipefail

if [ "$1" = "systemctl" ] && [ "$2" = "stop" ]; then
    exit 0
fi
if [ "$1" = "iptables" ] && [ "$2" = "-nL" ]; then
    if [ "$3" = "OPENHANDS-EGRESS" ]; then
        exit 0
    fi
    echo 'iptables: No chain/target/match by that name.' >&2
    exit 1
fi
exit 2
EOF
cat > "${STOP_DOCKER}" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
[ "$1" = "ps" ] || exit 2
exit 0
EOF
chmod +x "${STOP_SUDO}" "${STOP_DOCKER}"

STOP_RC=0
set +e
PATH="${STOP_TEST_DIR}:${PATH}" \
DOCKER_BIN="${STOP_DOCKER}" \
STOP_VERIFY_DELAY=0 \
    /usr/bin/bash deployment/scripts/stop.sh > "${STOP_TEST_DIR}/stop.log" 2>&1
STOP_RC=$?
set -e

grep -q 'sudo iptables' deployment/scripts/stop.sh \
    && pass "stop.sh: iptables checks use sudo" \
    || fail "stop.sh: iptables checks do not use sudo"
grep -q 'OPENHANDS-EGRESS' deployment/scripts/stop.sh \
    && pass "stop.sh: checks OPENHANDS-EGRESS" \
    || fail "stop.sh: missing OPENHANDS-EGRESS check"
grep -q 'OPENHANDS-INPUT' deployment/scripts/stop.sh \
    && pass "stop.sh: checks OPENHANDS-INPUT" \
    || fail "stop.sh: missing OPENHANDS-INPUT check"
[ "${STOP_RC}" -ne 0 ] \
    && pass "stop.sh: remaining chain forces non-zero (rc=${STOP_RC})" \
    || fail "stop.sh: remaining chain incorrectly returned success"

# ── 19. Egress positive checks ──
echo ""
echo "--- Egress positive checks ---"
grep -q 'expect_ok "External HTTP"' deployment/network/check-egress.sh \
    && pass "egress: External HTTP positive test" \
    || fail "egress: missing External HTTP test"
grep -q 'expect_ok "External HTTPS"' deployment/network/check-egress.sh \
    && pass "egress: External HTTPS positive test" \
    || fail "egress: missing External HTTPS test"

# ── 20. Supervisor static invariants ──
echo ""
echo "--- Supervisor static invariants ---"
grep -q 'wait_pid' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: wait_pid функция" || fail "supervisor: нет wait_pid"
grep -q 'set +e' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: set +e перед wait" || fail "supervisor: нет set +e"
grep -q 'TERMINATED_BY_SIGNAL' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: TERMINATED_BY_SIGNAL" || fail "supervisor: нет TERMINATED_BY_SIGNAL"
grep -q 'COMPOSE_COLLECTED=false' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: COMPOSE_COLLECTED" || fail "supervisor: нет COMPOSE_COLLECTED"
grep -q 'WATCHDOG_COLLECTED=false' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: WATCHDOG_COLLECTED" || fail "supervisor: нет WATCHDOG_COLLECTED"
grep -q 'eval ' deployment/scripts/run-supervised.sh 2>/dev/null && fail "supervisor: eval запрещён" || pass "supervisor: без eval"

# ── 21. Purge extended checks ──
echo ""
echo "--- Purge extended checks ---"
grep -q '\${1:-}' deployment/scripts/purge-test.sh && pass "purge: \${1:-}" || fail "purge: нет \${1:-}"
grep -q 'OPENHANDS-EGRESS' deployment/scripts/purge-test.sh && pass "purge: проверка OPENHANDS-EGRESS" || fail "purge: нет проверки OPENHANDS-EGRESS"
grep -q 'OPENHANDS-INPUT' deployment/scripts/purge-test.sh && pass "purge: проверка OPENHANDS-INPUT" || fail "purge: нет проверки OPENHANDS-INPUT"
grep -q '\-\-one-file-system' deployment/scripts/purge-test.sh && pass "purge: --one-file-system" || fail "purge: нет --one-file-system"
grep -q 'docker compose.*down' deployment/scripts/purge-test.sh && grep -A2 'compose down' deployment/scripts/purge-test.sh | grep -q '|| true' && fail "purge: compose down скрывает ошибку || true" || pass "purge: compose down без || true"

# ── 22. Path consistency ──
echo ""
echo "--- Path consistency ---"
grep -q '/srv/openhands-agent' deployment/compose.yaml deployment/systemd/openhands-agent.service 2>/dev/null && pass "Пути консистентны" || fail "Пути не консистентны"

echo ""
echo "=== Результат: ${PASSED} passed, ${FAILED} failed ==="
[ "${FAILED}" -eq 0 ] || exit 1
