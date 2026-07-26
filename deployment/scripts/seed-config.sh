#!/usr/bin/bash
# OpenHands Agent Canvas — развёртывание конфигурации из шаблонов
# Подставляет DEEPSEEK_API_KEY из secrets/.env в JSON-шаблоны.
# Без --force не перезаписывает существующие файлы.
set -euo pipefail

FORCE=false
if [ "${1:-}" = "--force" ]; then
    FORCE=true
    shift
fi

BASE="${OPENHANDS_BASE:-/srv/openhands-agent}"
SECRETS="${BASE}/secrets/.env"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="${SCRIPT_DIR}/../config"
TARGET="${BASE}/config"
OWNER="10001:10001"
PLACEHOLDER="DEEPSEEK_API_KEY_PLACEHOLDER"

echo "=== Seed Agent Canvas config ==="

# 1. Проверить secrets/.env
if [ ! -f "${SECRETS}" ]; then
    echo "ERROR: ${SECRETS} not found."
    echo "Create it from deployment/.env.example and set DEEPSEEK_API_KEY."
    exit 1
fi

# shellcheck disable=SC1090
source "${SECRETS}"

if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
    echo "ERROR: DEEPSEEK_API_KEY is empty or not set in ${SECRETS}."
    echo "Add: DEEPSEEK_API_KEY=sk-your-key"
    exit 1
fi

# 2. Проверить, что ключ не плейсхолдер
if [ "${DEEPSEEK_API_KEY}" = "DEEPSEEK_API_KEY_PLACEHOLDER" ] || [ "${DEEPSEEK_API_KEY}" = "sk-your-deepseek-api-key" ]; then
    echo "ERROR: DEEPSEEK_API_KEY still has placeholder value."
    echo "Replace with your actual DeepSeek API key in ${SECRETS}."
    exit 1
fi

# 3. Ключ не в логах
echo "DEEPSEEK_API_KEY: [present, length=${#DEEPSEEK_API_KEY}]"

# 4. Копировать и подставить
mkdir -p "${TARGET}/agent-profiles" "${TARGET}/profiles"

seed_one() {
    local src="$1"
    local dst="$2"

    if [ -f "${dst}" ] && [ "${FORCE}" != "true" ]; then
        echo "SKIP ${dst} — already exists. Use --force to overwrite."
        return
    fi

    cp "${src}" "${dst}"
    sed -i "s|${PLACEHOLDER}|${DEEPSEEK_API_KEY}|g" "${dst}"
    chown "${OWNER}" "${dst}" 2>/dev/null || true
    chmod 600 "${dst}"
    echo "OK   ${dst}"
}

seed_one "${TEMPLATES}/settings.json"                "${TARGET}/settings.json"
seed_one "${TEMPLATES}/profiles/deepseek-chat.json"   "${TARGET}/profiles/deepseek-chat.json"
seed_one "${TEMPLATES}/agent-profiles/default.json"   "${TARGET}/agent-profiles/default.json"

# 5. Проверить отсутствие плейсхолдера во всех созданных файлах
for check_file in \
    "${TARGET}/settings.json" \
    "${TARGET}/profiles/deepseek-chat.json" \
    "${TARGET}/agent-profiles/default.json"; do
    if grep -q "${PLACEHOLDER}" "${check_file}" 2>/dev/null; then
        echo "ERROR: Placeholder still present in ${check_file}"
        exit 1
    fi
done

echo ""
echo "Config seeded successfully."
