#!/usr/bin/bash
# OpenHands Agent Canvas — runtime-проверка
# Завершается с ненулевым кодом при любой ошибке.
# Не выводит значение LOCAL_BACKEND_API_KEY.
set -euo pipefail

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
SECRETS_FILE="${BASE}/secrets/.env"

echo "=== Runtime validation ==="

# --- secrets/.env ---
if [ ! -f "${SECRETS_FILE}" ]; then
    echo "❌ ${SECRETS_FILE} не существует"
    exit 1
fi

PERMS=$(stat -c "%a" "${SECRETS_FILE}" 2>/dev/null)
if [ "${PERMS}" != "600" ]; then
    echo "❌ ${SECRETS_FILE} права ${PERMS}, требуется 600"
    exit 1
fi

# Извлечь значение LOCAL_BACKEND_API_KEY
KEY_VALUE=$(grep -E '^LOCAL_BACKEND_API_KEY=' "${SECRETS_FILE}" | head -1 | cut -d'=' -f2-)

if [ -z "${KEY_VALUE}" ]; then
    echo "❌ LOCAL_BACKEND_API_KEY не задан или пуст"
    exit 1
fi

# Запрещённые шаблоны
FORBIDDEN="your-generated-key-here changeme example placeholder"
for pattern in ${FORBIDDEN}; do
    if [ "${KEY_VALUE}" = "${pattern}" ]; then
        echo "❌ LOCAL_BACKEND_API_KEY содержит запрещённый шаблон: ${pattern}"
        exit 1
    fi
done

# Проверка на ***
if echo "${KEY_VALUE}" | grep -q '\*\*\*'; then
    echo "❌ LOCAL_BACKEND_API_KEY содержит *** (не заменён)"
    exit 1
fi

# Минимальная длина
if [ ${#KEY_VALUE} -lt 16 ]; then
    echo "❌ LOCAL_BACKEND_API_KEY слишком короткий (${#KEY_VALUE} символов, минимум 16)"
    exit 1
fi

# Пробелы и CRLF
if echo "${KEY_VALUE}" | grep -q '[[:space:]]'; then
    echo "❌ LOCAL_BACKEND_API_KEY содержит пробелы/непечатные символы"
    exit 1
fi

echo "  ✅ LOCAL_BACKEND_API_KEY задан (длина: ${#KEY_VALUE})"

# --- Каталоги ---
for d in config secrets test-workspace; do
    DIR="${BASE}/${d}"
    if [ ! -d "${DIR}" ]; then
        echo "❌ Каталог ${DIR} не существует. Запустите prepare.sh"
        exit 1
    fi
    DIR_PERMS=$(stat -c "%a" "${DIR}" 2>/dev/null)
    if [ "${DIR_PERMS}" != "700" ]; then
        echo "❌ ${DIR} права ${DIR_PERMS}, требуется 700"
        exit 1
    fi
done
echo "  ✅ Каталоги config/secrets/test-workspace: 700"

# --- compose.yaml ---
if [ ! -f "${COMPOSE_FILE}" ]; then
    echo "❌ ${COMPOSE_FILE} не существует"
    exit 1
fi
echo "  ✅ compose.yaml существует"

# --- WireGuard ---
if ! ip link show wg0 >/dev/null 2>&1; then
    echo "❌ Интерфейс wg0 не существует"
    exit 1
fi
if ! ip addr show wg0 2>/dev/null | grep -q '10.77.0.2'; then
    echo "❌ Адрес 10.77.0.2 не найден на wg0"
    exit 1
fi
echo "  ✅ wg0: 10.77.0.2"

# --- Docker ---
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker недоступен"
    exit 1
fi
echo "  ✅ Docker доступен"

# --- docker compose config ---
if ! docker compose -f "${COMPOSE_FILE}" config >/dev/null 2>&1; then
    echo "❌ docker compose config не прошёл"
    exit 1
fi
echo "  ✅ docker compose config OK"

# --- Firewall-скрипты ---
for script in apply-egress-rules.sh check-egress.sh remove-egress-rules.sh; do
    if [ ! -f "${BASE}/deployment/network/${script}" ]; then
        echo "❌ ${BASE}/deployment/network/${script} не существует"
        exit 1
    fi
done
echo "  ✅ Firewall-скрипты на месте"

echo ""
echo "=== Validation PASSED ==="
