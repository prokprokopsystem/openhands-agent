#!/usr/bin/bash
# OpenHands Agent Canvas — подготовка каталогов
# Только создаёт каталоги и права. Контейнер не запускает.
set -euo pipefail

BASE="/srv/openhands-agent"
HOST_OWNER="igor:igor"
CONTAINER_OWNER="10001:10001"
BROKER_KEY="${BASE}/secrets/broker-mini-server.key"

echo "=== OpenHands Agent Canvas — подготовка каталогов ==="

# Каталоги, в которые пишет процесс Agent Canvas внутри контейнера.
for d in config work-workspace; do
    mkdir -p "${BASE}/${d}"
    chown -R "${CONTAINER_OWNER}" "${BASE}/${d}"
    chmod 700 "${BASE}/${d}"
done

# Каталоги документации — read-only для контейнера.
mkdir -p "${BASE}/docs"
chown -R "${HOST_OWNER}" "${BASE}/docs"
chmod 755 "${BASE}/docs"

# Хостовые runtime-каталоги. Обычные secrets обслуживает igor, но broker key
# исключён из общей рекурсивной политики: он доступен только root и Canvas GID.
mkdir -p "${BASE}/secrets" "${BASE}/logs"
chown "${HOST_OWNER}" "${BASE}/secrets" "${BASE}/logs"
chmod 700 "${BASE}/secrets" "${BASE}/logs"
find "${BASE}/secrets" -mindepth 1 ! -path "${BROKER_KEY}" \
    -exec chown -h "${HOST_OWNER}" -- {} +
chown -R "${HOST_OWNER}" "${BASE}/logs"

if [ -e "${BROKER_KEY}" ] || [ -L "${BROKER_KEY}" ]; then
    [ -f "${BROKER_KEY}" ] && [ ! -L "${BROKER_KEY}" ] \
        || { echo "broker-mini-server.key должен быть обычным файлом" >&2; exit 1; }
    chown root:10001 "${BROKER_KEY}"
    chmod 0640 "${BROKER_KEY}"
fi

if [ -f "${BASE}/secrets/.env" ]; then
    chmod 600 "${BASE}/secrets/.env"
    chown "${HOST_OWNER}" "${BASE}/secrets/.env"
    echo "secrets/.env — права 600"
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

# Развернуть конфигурацию Canvas из шаблонов с подстановкой DEEPSEEK_API_KEY.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -n "$(find "${BASE}/config" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "Existing server-side Canvas config preserved; bootstrap seed skipped."
else
    "${SCRIPT_DIR}/seed-config.sh"
fi
