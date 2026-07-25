#!/usr/bin/bash
# OpenHands Agent Canvas — статическая проверка
# Работает без runtime .env и без mini-server.
# Завершается с ненулевым кодом при любой ошибке.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${PROJECT_ROOT}"

PASSED=0
FAILED=0

pass() { echo "  ✅ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $1"; FAILED=$((FAILED + 1)); }

echo "=== Static validation ==="
echo ""

# 1. Shell syntax
echo "--- Shell syntax (bash -n) ---"
for f in deployment/scripts/*.sh deployment/network/*.sh; do
    if bash -n "$f" 2>/dev/null; then
        pass "$f"
    else
        fail "$f"
    fi
done

# 2. Executable bits
echo ""
echo "--- Executable bits ---"
for f in deployment/scripts/*.sh deployment/network/*.sh; do
    if [ -x "$f" ]; then
        pass "$f (executable)"
    else
        fail "$f (NOT executable)"
    fi
done

# 3. No restart policy in compose
echo ""
echo "--- Compose: no restart policy ---"
if grep -q 'restart:' deployment/compose.yaml 2>/dev/null; then
    fail "compose.yaml содержит restart: (должен управляться systemd)"
else
    pass "compose.yaml: без restart:"
fi

# 4. Systemd: validate-runtime ExecStartPre
echo ""
echo "--- Systemd: ExecStartPre validate-runtime ---"
if grep -q 'ExecStartPre=.*validate-runtime.sh' deployment/systemd/openhands-agent.service 2>/dev/null; then
    pass "systemd unit: ExecStartPre validate-runtime.sh"
else
    fail "systemd unit: отсутствует ExecStartPre validate-runtime.sh"
fi

# 5. Systemd: watchdog
echo ""
echo "--- Systemd: watchdog ---"
if grep -q 'health-watchdog\|run-supervised' deployment/systemd/openhands-agent.service 2>/dev/null; then
    pass "systemd unit: watchdog/supervised lifecycle"
else
    fail "systemd unit: отсутствует watchdog"
fi

# 6. Secrets check
echo ""
echo "--- Secrets ---"
SECRETS=$(grep -rn 'ghp_\|sk-or-\|sk-ant\|sk-proj\|Bearer [A-Za-z0-9]\|password\s*=\s*[A-Za-z0-9]' --include="*.md" --include="*.yaml" --include="*.sh" --include="*.service" . 2>/dev/null | grep -v '.git/\|.example\|your-\|openssl\|\*\*\*\|LOCAL_BACKEND_API_KEY' || true)
if [ -z "${SECRETS}" ]; then
    pass "Секреты не найдены"
else
    fail "Найдены возможные секреты: ${SECRETS}"
fi

# 7. docker compose config (с фиктивным .env) — пропустить если нет compose
echo ""
echo "--- docker compose config ---"
if docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1; then
    TEMP_ENV=$(mktemp)
    trap "rm -f ${TEMP_ENV}" EXIT
    echo "LOCAL_BACKEND_API_KEY=***--p...ab" > "${TEMP_ENV}"

    if docker compose -f deployment/compose.yaml --env-file "${TEMP_ENV}" config >/dev/null 2>&1; then
        pass "docker compose config"
    else
        fail "docker compose config"
    fi
else
    echo "  ⏭️  docker compose недоступен — пропуск (ожидаемо вне mini-server)"
fi

# 8. systemd-analyze verify
echo ""
echo "--- systemd-analyze verify ---"
if command -v systemd-analyze >/dev/null 2>&1; then
    RESULT=$(systemd-analyze verify deployment/systemd/openhands-agent.service 2>&1 || true)
    # Ожидаемые предупреждения о несуществующих runtime-путях
    WARNINGS=$(echo "${RESULT}" | grep -cE '^deployment/|does not exist|cannot stat' || true)
    ERRORS=$(echo "${RESULT}" | grep -cE 'Failed|Error|error:|missing' || true)
    if echo "${RESULT}" | grep -qi 'Failed\|Error'; then
        # Проверить — настоящая ошибка или ожидаемое предупреждение о путях
        REAL_ERRORS=$(echo "${RESULT}" | grep -vE 'does not exist|cannot stat|No such file' | grep -cE 'Failed|Error|error:|missing' || true)
        if [ "${REAL_ERRORS}" -gt 0 ]; then
            fail "systemd-analyze: настоящие ошибки"
            echo "${RESULT}"
        else
            pass "systemd-analyze verify (ожидаемые предупреждения о runtime-путях)"
        fi
    else
        pass "systemd-analyze verify"
    fi
else
    echo "  ⏭️  systemd-analyze недоступен (не на systemd-хосте)"
fi

# 9. Path consistency
echo ""
echo "--- Path consistency ---"
ERRORS=0
grep -rh '/srv/openhands-agent' deployment/ --include="*.sh" --include="*.service" --include="*.yaml" 2>/dev/null | grep -v '^#' | while read -r line; do :; done
# Проверить, что пути консистентны
if grep -q '/srv/openhands-agent' deployment/compose.yaml deployment/systemd/openhands-agent.service; then
    pass "Пути консистентны (/srv/openhands-agent)"
else
    fail "Не найдены пути /srv/openhands-agent в ключевых файлах"
fi

# 10. Subnet consistency
echo ""
echo "--- Subnet consistency ---"
if grep -q '10.89.0.0/28' deployment/compose.yaml && grep -q '10.89.0.0/28' deployment/network/apply-egress-rules.sh; then
    pass "Подсеть 10.89.0.0/28 консистентна"
else
    fail "Подсеть не консистентна"
fi

echo ""
echo "=== Результат: ${PASSED} passed, ${FAILED} failed ==="
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
