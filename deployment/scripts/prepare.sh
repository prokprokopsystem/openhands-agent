#!/usr/bin/bash
# OpenHands Agent Canvas — подготовка каталогов
# Только создаёт каталоги и права. Контейнер не запускает.
set -euo pipefail

BASE="/srv/openhands-agent"
HOST_OWNER="igor:igor"
CONTAINER_OWNER="10001:10001"

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

# Хостовые runtime-каталоги. Секреты создаёт и обслуживает igor.
for d in secrets logs; do
    mkdir -p "${BASE}/${d}"
    chown -R "${HOST_OWNER}" "${BASE}/${d}"
    chmod 700 "${BASE}/${d}"
done

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
"${SCRIPT_DIR}/seed-config.sh"
