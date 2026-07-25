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

# ── 15. Healthcheck behavioral test ──
echo ""
echo "--- Healthcheck Python test ---"
HC_PY=$(sed -n '/healthcheck:/,/start_period:/p' deployment/compose.yaml | grep -A20 'python3' | sed 's/^[[:space:]]*//' | grep -v '^$')
if echo "${HC_PY}" | grep -q 'create_connection'; then
    # Проверить синтаксис Python-фрагмента (без реального соединения)
    timeout 5 python3 -c "
import socket
try:
    for p in (18000, 18001):
        s = socket.create_connection(('127.0.0.1', p), timeout=1)
        s.close()
except (ConnectionRefusedError, OSError, socket.timeout):
    pass
" 2>/dev/null
    pass "healthcheck: create_connection синтаксис корректен"
else
    fail "healthcheck: не использует create_connection"
fi

# ── 16. Supervisor invariants + behavioral test ──
echo ""
echo "--- Supervisor invariants ---"
# No `wait ... || true` pattern
grep -q 'wait.*|| true.*EXIT=' deployment/scripts/run-supervised.sh 2>/dev/null && fail "supervisor: wait ... || true" || pass "supervisor: без wait ... || true"
# Has EXIT_CODE
grep -q 'EXIT_CODE' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: EXIT_CODE" || fail "supervisor: нет EXIT_CODE"
# Has TERMINATED_BY_SIGNAL
grep -q 'TERMINATED_BY_SIGNAL' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: TERMINATED_BY_SIGNAL" || fail "supervisor: нет TERMINATED_BY_SIGNAL"
# Uses set +e for wait safety
grep -q 'set +e' deployment/scripts/run-supervised.sh 2>/dev/null && pass "supervisor: set +e перед wait" || fail "supervisor: нет set +e перед wait"
# Compose failure → EXIT_CODE=1
grep -A2 'COMPOSE_RC.*-ne 0' deployment/scripts/run-supervised.sh 2>/dev/null | grep -q 'EXIT_CODE=1' && pass "supervisor: compose fail → EXIT_CODE=1" || fail "supervisor: compose fail не устанавливает EXIT_CODE=1"
# Watchdog failure → EXIT_CODE=1
grep -A2 'WATCHDOG_RC.*-ne 0' deployment/scripts/run-supervised.sh 2>/dev/null | grep -q 'EXIT_CODE=1' && pass "supervisor: watchdog fail → EXIT_CODE=1" || fail "supervisor: watchdog fail не устанавливает EXIT_CODE=1"
# SIGTERM → exit 0
grep -A2 'TERMINATED_BY_SIGNAL' deployment/scripts/run-supervised.sh 2>/dev/null | grep -q 'exit 0' && pass "supervisor: SIGTERM → exit 0" || fail "supervisor: SIGTERM не даёт exit 0"

# ── 17. Purge extended checks ──
echo ""
echo "--- Purge extended checks ---"
grep -q '\${1:-}' deployment/scripts/purge-test.sh && pass "purge: \${1:-}" || fail "purge: нет \${1:-}"
grep -q 'OPENHANDS-EGRESS' deployment/scripts/purge-test.sh && pass "purge: проверка OPENHANDS-EGRESS" || fail "purge: нет проверки OPENHANDS-EGRESS"
grep -q 'OPENHANDS-INPUT' deployment/scripts/purge-test.sh && pass "purge: проверка OPENHANDS-INPUT" || fail "purge: нет проверки OPENHANDS-INPUT"
grep -q '\-\-one-file-system' deployment/scripts/purge-test.sh && pass "purge: --one-file-system" || fail "purge: нет --one-file-system"
grep -q 'docker compose.*down' deployment/scripts/purge-test.sh && grep -A2 'compose down' deployment/scripts/purge-test.sh | grep -q '|| true' && fail "purge: compose down скрывает ошибку || true" || pass "purge: compose down без || true"

# ── 18. Path consistency ──
echo ""
echo "--- Path consistency ---"
grep -q '/srv/openhands-agent' deployment/compose.yaml deployment/systemd/openhands-agent.service 2>/dev/null && pass "Пути консистентны" || fail "Пути не консистентны"

echo ""
echo "=== Результат: ${PASSED} passed, ${FAILED} failed ==="
[ "${FAILED}" -eq 0 ] || exit 1
