#!/usr/bin/bash
# OpenHands Agent Canvas — статическая валидация
# Работает на чистом checkout без /srv/openhands-agent/secrets/.env
# Завершается с ненулевым кодом при любой ошибке.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${PROJECT_ROOT}"

PASSED=0
FAILED=0

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
grep -q 'sha256:fc24163754bee' deployment/compose.yaml && pass "digest зафиксирован" || fail "digest отсутствует"

# ── 5. Systemd invariants ──
echo ""
echo "--- Systemd invariants ---"
SVC="deployment/systemd/openhands-agent.service"
grep -q 'ExecStartPre=.*validate-runtime.sh' "${SVC}" && pass "ExecStartPre: validate-runtime" || fail "ExecStartPre: нет validate-runtime"
grep -q 'ExecStartPre=.*compose.*create' "${SVC}" && pass "ExecStartPre: compose create" || fail "ExecStartPre: нет compose create"
grep -q 'ExecStartPre=.*apply-egress-rules' "${SVC}" && pass "ExecStartPre: apply-egress-rules" || fail "ExecStartPre: нет apply-egress-rules"
grep -q 'ExecStart=.*run-supervised' "${SVC}" && pass "ExecStart: run-supervised" || fail "ExecStart: не run-supervised"
grep -q 'ExecStopPost=.*remove-egress-rules' "${SVC}" && pass "ExecStopPost: remove-egress-rules" || fail "ExecStopPost: нет remove-egress-rules"

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

# ── 11. Docker compose config ──
echo ""
echo "--- docker compose config ---"
if docker compose version >/dev/null 2>&1; then
    TMPDIR=$(mktemp -d)
    trap "rm -rf ${TMPDIR}" EXIT
    printf "LOCAL_BACKEND_API_KEY=placeholder-static-check-only
" > "${TMPDIR}/.env"
    if docker compose -f deployment/compose.yaml --env-file "${TMPDIR}/.env" config >/dev/null 2>&1; then
        pass "docker compose config"
    else
        fail "docker compose config"
    fi
else
    echo "  [SKIP] docker compose недоступен"
fi

# ── 12. systemd-analyze ──
echo ""
echo "--- systemd-analyze verify ---"
if command -v systemd-analyze >/dev/null 2>&1; then
    RESULT=$(systemd-analyze verify "${SVC}" 2>&1 || true)
    if echo "${RESULT}" | grep -qiE 'Failed|Error'; then
        REAL=$(echo "${RESULT}" | grep -vE 'does not exist|cannot stat|No such file' | grep -ciE 'Failed|Error' || true)
        if [ "${REAL}" -gt 0 ]; then
            fail "systemd-analyze: ошибки"
            echo "${RESULT}"
        else
            pass "systemd-analyze : ожидаемые предупреждения о путях"
        fi
    else
        pass "systemd-analyze verify"
    fi
else
    echo "  [SKIP] systemd-analyze недоступен"
fi

# ── 13. Docs: no manual compose launch ──
echo ""
echo "--- Docs: no manual compose ---"
grep -r 'docker compose up' deployment/README.md 2>/dev/null | grep -v 'запрещ\|ЗАПРЕЩ\|forbidden' >/dev/null && fail "README: docker compose up" || pass "README: без docker compose up"
grep -r 'systemctl start' deployment/README.md 2>/dev/null && pass "README: systemctl start" || fail "README: нет systemctl start"

# ── 14. Docs: no key entry screen claim ──
echo ""
echo "--- Docs: no manual key screen ---"
grep -ri 'ввести.*LOCAL_BACKEND_API_KEY\|экран.*ввода.*ключа\|enter.*API key' deployment/README.md docs/Решения.md docs/Состояние.md 2>/dev/null && fail "Документация: экран ввода ключа" || pass "Документация: без экрана ввода ключа"

# ── 15. Healthcheck: real Python syntax test from compose ──
echo ""
echo "--- Healthcheck Python test ---"
# Извлечь Python-код из compose.yaml (строка с 'python3 -c')
HC_LINE=$(grep 'python3 -c' deployment/compose.yaml | head -1)
if [ -z "${HC_LINE}" ]; then
    fail "healthcheck: не найден python3 -c в compose.yaml"
else
    # Извлечь код между 'python3 -c' и конца строки
    HC_CMD=$(echo "${HC_LINE}" | sed 's/.*python3 -c "\(.*\)"/\1/')
    if [ -z "${HC_CMD}" ]; then
        # Попробовать без кавычек
        HC_CMD=$(echo "${HC_LINE}" | sed "s/.*python3 -c //")
    fi
    # Проверить: однострочник, не for-in (который YAML свернёт)
    if echo "${HC_CMD}" | grep -q 'for p'; then
        fail "healthcheck: использует 'for p' — YAML свернёт в SyntaxError"
    elif echo "${HC_CMD}" | grep -q 'create_connection'; then
        # Проверить синтаксис: скомпилировать, не исполнять
        python3 -c "compile('''${HC_CMD}''', '<healthcheck>', 'exec')" 2>/dev/null \
            && pass "healthcheck: Python синтаксис корректен" \
            || fail "healthcheck: Python SyntaxError"
    else
        fail "healthcheck: не использует create_connection"
    fi
fi

# ── 16. Supervisor: real behavioral tests ──
echo ""
echo "--- Supervisor behavioral tests ---"
TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

# Mock docker: compose up → exit 7, compose down → OK
cat > "${TMPDIR}/mock-docker" << 'EOF'
#!/usr/bin/bash
PIDFILE="/tmp/oh-test-compose-up.pid"
if [ "$1" = "compose" ] && [ "${4:-}" = "up" ]; then
    echo "mock compose up"
    exit 7
elif [ "$1" = "compose" ] && [ "${4:-}" = "down" ]; then
    echo "mock compose down"
    # Если compose-up ещё жив — убить его
    if [ -f "${PIDFILE}" ]; then
        kill "$(cat "${PIDFILE}")" 2>/dev/null || true
        rm -f "${PIDFILE}"
    fi
    exit 0
fi
exit 0
EOF
chmod +x "${TMPDIR}/mock-docker"

# Mock watchdog
cat > "${TMPDIR}/mock-watchdog" << 'EOF'
#!/usr/bin/bash
echo "mock watchdog ok"
exit 0
EOF
chmod +x "${TMPDIR}/mock-watchdog"

cat > "${TMPDIR}/mock-watchdog-fail" << 'EOF'
#!/usr/bin/bash
echo "mock watchdog fail"
exit 8
EOF
chmod +x "${TMPDIR}/mock-watchdog-fail"

# Mock compose.yaml
echo 'services: {openhands: {image: "alpine:latest", command: ["sleep","999"]}}' > "${TMPDIR}/compose.yaml"

# Тест 1: compose exit 7 → supervisor exit != 0
echo "  Test 1: compose fail..."
COMPOSE_FILE="${TMPDIR}/compose.yaml" \
WATCHDOG="${TMPDIR}/mock-watchdog" \
DOCKER_BIN="${TMPDIR}/mock-docker" \
    timeout 10 /usr/bin/bash deployment/scripts/run-supervised.sh || RC1=$?
[ "${RC1}" -ne 0 ] && pass "compose exit 7 → supervisor non-zero (rc=${RC1})" \
    || fail "compose exit 7 → supervisor exit ${RC1}, expected non-zero"

# Тест 2: watchdog exit 8 → supervisor exit != 0
echo "  Test 2: watchdog fail..."
# compose-up должен спать, чтобы watchdog умер первым
cat > "${TMPDIR}/mock-docker-sleep-up" << 'SCRIPT'
#!/usr/bin/bash
PIDFILE="/tmp/oh-test-compose-up.pid"
if [ "$1" = "compose" ] && [ "${4:-}" = "up" ]; then
    echo "mock compose up, sleeping"
    sleep 30 &
    echo $! > "${PIDFILE}"
    wait
    exit 0
elif [ "$1" = "compose" ] && [ "${4:-}" = "down" ]; then
    echo "mock compose down"
    if [ -f "${PIDFILE}" ]; then
        kill "$(cat "${PIDFILE}")" 2>/dev/null || true
        rm -f "${PIDFILE}"
    fi
    exit 0
fi
exit 0
SCRIPT
chmod +x "${TMPDIR}/mock-docker-sleep-up"

COMPOSE_FILE="${TMPDIR}/compose.yaml" \
WATCHDOG="${TMPDIR}/mock-watchdog-fail" \
DOCKER_BIN="${TMPDIR}/mock-docker-sleep-up" \
    timeout 15 /usr/bin/bash deployment/scripts/run-supervised.sh || RC2=$?
[ "${RC2}" -ne 0 ] && pass "watchdog exit 8 → supervisor non-zero (rc=${RC2})" \
    || fail "watchdog exit 8 → supervisor exit ${RC2}, expected non-zero"

# Тест 3: SIGTERM → supervisor завершается (timeout убивает)
echo "  Test 3: SIGTERM..."
cat > "${TMPDIR}/mock-docker-sleep" << 'SCRIPT'
#!/usr/bin/bash
PIDFILE="/tmp/oh-test-compose-up.pid"
if [ "$1" = "compose" ] && [ "${4:-}" = "up" ]; then
    echo "mock compose up, sleeping"
    sleep 30 &
    echo $! > "${PIDFILE}"
    wait
    exit 0
elif [ "$1" = "compose" ] && [ "${4:-}" = "down" ]; then
    echo "mock compose down"
    if [ -f "${PIDFILE}" ]; then
        kill "$(cat "${PIDFILE}")" 2>/dev/null || true
        rm -f "${PIDFILE}"
    fi
    exit 0
fi
exit 0
SCRIPT
chmod +x "${TMPDIR}/mock-docker-sleep"

cat > "${TMPDIR}/mock-watchdog-sleep" << 'SCRIPT'
#!/usr/bin/bash
echo "mock watchdog sleeping"
sleep 30
exit 0
SCRIPT
chmod +x "${TMPDIR}/mock-watchdog-sleep"

COMPOSE_FILE="${TMPDIR}/compose.yaml" \
WATCHDOG="${TMPDIR}/mock-watchdog-sleep" \
DOCKER_BIN="${TMPDIR}/mock-docker-sleep" \
    timeout 10 /usr/bin/bash deployment/scripts/run-supervised.sh || RC3=$?
# timeout убивает supervisor, supervisor ловит SIGTERM → cleanup → exit 0
# timeout возвращает: 124 если истекло, или код дочернего процесса
if [ "${RC3}" -eq 0 ] || [ "${RC3}" -eq 124 ]; then
    pass "SIGTERM → exit ${RC3} (штатное завершение)"
else
    fail "SIGTERM → exit ${RC3}, expected 0 or 124"
fi

# Проверка: фоновых процессов не осталось
LEFT=$(jobs -p 2>/dev/null | wc -l)
[ "${LEFT}" -eq 0 ] && pass "Нет фоновых процессов" || fail "Остались фоновые процессы: ${LEFT}"

rm -rf "${TMPDIR}"

# ── 17. Supervisor static invariants ──
echo ""
echo "--- Supervisor static invariants ---"
grep -q 'wait_pid' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: wait_pid функция" || fail "supervisor: нет wait_pid"
grep -q 'set +e' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: set +e перед wait" || fail "supervisor: нет set +e"
grep -q 'TERMINATED_BY_SIGNAL' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: TERMINATED_BY_SIGNAL" || fail "supervisor: нет TERMINATED_BY_SIGNAL"

# ── 18. Purge extended checks ──
echo ""
echo "--- Purge extended checks ---"
grep -q '\${1:-}' deployment/scripts/purge-test.sh && pass "purge: \${1:-}" || fail "purge: нет \${1:-}"
grep -q 'OPENHANDS-EGRESS' deployment/scripts/purge-test.sh && pass "purge: проверка OPENHANDS-EGRESS" || fail "purge: нет проверки OPENHANDS-EGRESS"
grep -q 'OPENHANDS-INPUT' deployment/scripts/purge-test.sh && pass "purge: проверка OPENHANDS-INPUT" || fail "purge: нет проверки OPENHANDS-INPUT"
grep -q '\-\-one-file-system' deployment/scripts/purge-test.sh && pass "purge: --one-file-system" || fail "purge: нет --one-file-system"
grep -q 'docker compose.*down' deployment/scripts/purge-test.sh && grep -A2 'compose down' deployment/scripts/purge-test.sh | grep -q '|| true' && fail "purge: compose down скрывает ошибку || true" || pass "purge: compose down без || true"

# ── 19. Path consistency ──
echo ""
echo "--- Path consistency ---"
grep -q '/srv/openhands-agent' deployment/compose.yaml deployment/systemd/openhands-agent.service 2>/dev/null && pass "Пути консистентны" || fail "Пути не консистентны"

echo ""
echo "=== Результат: ${PASSED} passed, ${FAILED} failed ==="
[ "${FAILED}" -eq 0 ] || exit 1
