#!/usr/bin/bash
# OpenHands Agent — валидация конфигурации broker
# Статические проверки: tools.yaml, wrapper, setup
# Запуск: ./validate-broker-config.sh
set -euo pipefail

BASE="${1:-/srv/openhands-agent}"
BROKER_DIR="${BASE}/deployment/broker"
TOOLS_FILE="${BROKER_DIR}/tools.yaml"
WRAPPER="${BROKER_DIR}/broker-wrapper.sh"
SETUP="${BROKER_DIR}/setup-broker.sh"

ok()    { printf '  [OK] %s\n' "$1"; }
warn()  { printf '  [WARN] %s\n' "$1"; }
fail()  { printf '  [FAIL] %s\n' "$1"; ERRORS=$((ERRORS+1)); }
skip()  { printf '  [SKIP] %s\n' "$1"; }

ERRORS=0

echo "=== Broker config validation ==="

# --- Файлы ---
[ -f "${TOOLS_FILE}" ]  && ok "tools.yaml exists"     || fail "tools.yaml not found"
[ -f "${WRAPPER}" ]     && ok "broker-wrapper.sh exists" || fail "broker-wrapper.sh not found"
[ -f "${SETUP}" ]       && ok "setup-broker.sh exists"   || fail "setup-broker.sh not found"
[ -x "${WRAPPER}" ]     && ok "broker-wrapper.sh executable" || fail "broker-wrapper.sh not executable"
[ -x "${SETUP}" ]       && ok "setup-broker.sh executable"   || fail "setup-broker.sh not executable"

# --- tools.yaml структура ---
if command -v python3 &>/dev/null; then
    VALID=$(
        python3 -c "
import yaml, sys
with open('${TOOLS_FILE}') as f:
    data = yaml.safe_load(f)
if not isinstance(data, dict):
    print('NOT_A_DICT'); sys.exit(1)
if 'tools' not in data:
    print('NO_TOOLS'); sys.exit(1)
tools = data['tools']
if not isinstance(tools, list):
    print('TOOLS_NOT_LIST'); sys.exit(1)
errors = []
for i, t in enumerate(tools):
    if 'name' not in t: errors.append(f'tool[{i}]: no name')
    if 'execute' not in t: errors.append(f'tool[{i}]: no execute')
    if 'risk' not in t: errors.append(f'tool[{i}]: no risk')
    if t.get('risk') not in ('A','B','C'): errors.append(f'tool[{i}]: invalid risk \"{t.get(\"risk\")}\"')
    if 'secrets' not in t: errors.append(f'tool[{i}]: no secrets field')
    if 'verify' not in t: errors.append(f'tool[{i}]: no verify field')
    if 'rollback' not in t: errors.append(f'tool[{i}]: no rollback field')
if errors:
    for e in errors: print(e)
    sys.exit(1)
print(f'OK: {len(tools)} tools')
" 2>&1
    )
    if echo "${VALID}" | grep -q "^OK"; then
        ok "tools.yaml structure: ${VALID}"
    else
        fail "tools.yaml: $(echo "${VALID}" | head -1)"
    fi
else
    skip "python3 not available — skip YAML validation"
fi

# --- Проверка уровней риска в tools.yaml ---
if command -v python3 &>/dev/null; then
    LEVELS=$(python3 -c "
import yaml
with open('${TOOLS_FILE}') as f:
    data = yaml.safe_load(f)
for t in data['tools']:
    print(f\"{t['name']}: {t.get('risk','?')}\")
" 2>&1)
    echo ""
    echo "--- Risk levels ---"
    echo "${LEVELS}"
    echo ""
fi

# --- Итог ---
echo "=== Validation $( [ ${ERRORS} -eq 0 ] && echo 'PASSED' || echo "FAILED (${ERRORS} errors)") ==="
exit ${ERRORS}
