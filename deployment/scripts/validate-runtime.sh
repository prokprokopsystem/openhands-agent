#!/usr/bin/bash
# OpenHands Agent Canvas — runtime-проверка
# Обязательный ExecStartPre для systemd.
set -euo pipefail

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
SECRETS_FILE="${BASE}/secrets/.env"

ok()   { printf '  [OK] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; exit 1; }

echo "=== Runtime validation ==="

docker info >/dev/null 2>&1 || fail "Docker недоступен"
ok "Docker доступен"

docker compose version >/dev/null 2>&1 || fail "docker compose отсутствует"
ok "docker compose"

ip link show wg0 >/dev/null 2>&1 || fail "Интерфейс wg0 не существует"
ip addr show wg0 | grep -q '10.77.0.2' || fail "Адрес 10.77.0.2 не найден на wg0"
ok "wg0: 10.77.0.2"

[ -f "${COMPOSE_FILE}" ] || fail "${COMPOSE_FILE} не существует"
ok "compose.yaml"

for d in config secrets test-workspace logs; do
    DIR="${BASE}/${d}"
    [ -d "${DIR}" ] || fail "${DIR} не существует. Запустите prepare.sh"
    P=$(stat -c "%a" "${DIR}")
    [ "${P}" = "700" ] || fail "${DIR} права ${P}, требуется 700"
done
ok "Каталоги: 700"

[ -f "${SECRETS_FILE}" ] || fail "${SECRETS_FILE} не существует"
P=$(stat -c "%a" "${SECRETS_FILE}")
[ "${P}" = "600" ] || fail "${SECRETS_FILE} права ${P}, требуется 600"

COUNT=$(grep -cE '^LOCAL_BACKEND_API_KEY=.*' "${SECRETS_FILE}" || true)
[ "${COUNT}" -eq 1 ] || fail "${SECRETS_FILE}: найдено ${COUNT} строк LOCAL_BACKEND_API_KEY, нужна ровно 1"

KEY=$(grep -E '^LOCAL_BACKEND_API_KEY=.*' "${SECRETS_FILE}" | head -1 | cut -d'=' -f2-)
[ -n "${KEY}" ] || fail "LOCAL_BACKEND_API_KEY пуст"
[ ${#KEY} -ge 16 ] || fail "LOCAL_BACKEND_API_KEY слишком короткий: ${#KEY} символов, минимум 16"

for p in your-generated-key-here changeme example placeholder; do
    [ "${KEY}" != "${p}" ] || fail "LOCAL_BACKEND_API_KEY совпадает с шаблоном '${p}'"
done

echo "${KEY}" | grep -q '\*\*\*' && fail "LOCAL_BACKEND_API_KEY содержит ***, не заменён" || true
echo "${KEY}" | grep -q '[[:space:]]' && fail "LOCAL_BACKEND_API_KEY содержит пробелы" || true

ok "LOCAL_BACKEND_API_KEY задан, длина ${#KEY}"

for s in run-supervised.sh health-watchdog.sh prepare.sh; do
    [ -f "${BASE}/deployment/scripts/${s}" ] || fail "${s} не найден"
done
ok "Lifecycle-скрипты"

for s in apply-egress-rules.sh remove-egress-rules.sh check-egress.sh; do
    [ -f "${BASE}/deployment/network/${s}" ] || fail "network/${s} не найден"
done
ok "Firewall-скрипты"

docker compose -f "${COMPOSE_FILE}" config >/dev/null 2>&1 || fail "docker compose config не прошёл"
ok "docker compose config"

echo ""
echo "=== Validation PASSED ==="
