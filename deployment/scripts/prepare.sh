#!/usr/bin/bash
# OpenHands Agent Canvas — подготовка каталогов
# Только создаёт каталоги и права. Контейнер не запускает.
set -euo pipefail

BASE="${OPENHANDS_BASE:-/srv/openhands-agent}"
HOST_OWNER="igor:igor"
CONTAINER_OWNER="10001:10001"

echo "=== OpenHands Agent Canvas — подготовка каталогов ==="

# Существующее содержимое config является server-side state Canvas.
mkdir -p "${BASE}/config"
chown "${CONTAINER_OWNER}" "${BASE}/config"
chmod 700 "${BASE}/config"

mkdir -p "${BASE}/work-workspace"
chown -R "${CONTAINER_OWNER}" "${BASE}/work-workspace"
chmod 700 "${BASE}/work-workspace"

# Каталоги документации — read-only для контейнера.
mkdir -p "${BASE}/docs"
chown -R "${HOST_OWNER}" "${BASE}/docs"
chmod 755 "${BASE}/docs"

# Секреты создаёт и обслуживает igor. Содержимое не меняется: здесь могут
# находиться файлы с отдельной ownership policy.
mkdir -p "${BASE}/secrets"
chown "${HOST_OWNER}" "${BASE}/secrets"
chmod 700 "${BASE}/secrets"

mkdir -p "${BASE}/logs"
chown -R "${HOST_OWNER}" "${BASE}/logs"
chmod 700 "${BASE}/logs"

if [ -f "${BASE}/secrets/.env" ]; then
    echo "secrets/.env — существующий файл сохранён без изменений"
else
    echo "⚠️  secrets/.env ещё не создан. Создайте командой:"
    echo "   umask 077"
    echo "   printf 'LOCAL_BACKEND_API_KEY=%s\\n' \"\$(openssl rand -base64 32 | tr -d '\\n')\" > /srv/openhands-agent/secrets/.env"
    echo "   chmod 600 /srv/openhands-agent/secrets/.env"
fi

echo ""
echo "Каталоги подготовлены:"
ls -ld \
    "${BASE}/config" \
    "${BASE}/secrets" \
    "${BASE}/work-workspace" \
    "${BASE}/docs" \
    "${BASE}/logs"

# Развернуть конфигурацию только для пустого первого запуска. Существующая
# server-side config, включая profiles и conversations, не изменяется.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if find "${BASE}/config" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "Existing server-side Canvas config preserved; seed skipped."
else
    "${SCRIPT_DIR}/seed-config.sh"
fi
