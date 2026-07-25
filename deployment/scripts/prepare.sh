#!/usr/bin/bash
# OpenHands Agent Canvas — подготовка каталогов
# Только создаёт каталоги и права. Контейнер не запускает.
set -euo pipefail

BASE="/srv/openhands-agent"
OWNER="igor:igor"

echo "=== OpenHands Agent Canvas — подготовка каталогов ==="

for d in config secrets test-workspace logs; do
    mkdir -p "${BASE}/${d}"
    chmod 700 "${BASE}/${d}"
done

chown -R "${OWNER}" "${BASE}"

if [ -f "${BASE}/secrets/.env" ]; then
    chmod 600 "${BASE}/secrets/.env"
    chown "${OWNER}" "${BASE}/secrets/.env"
    echo "secrets/.env — права 600"
else
    echo "⚠️  secrets/.env ещё не создан. Создайте командой:"
    echo "   umask 077"
    echo "   printf 'LOCAL_BACKEND_API_KEY=%s\\n' \"\$(openssl rand -base64 32 | tr -d '\\n')\" > /srv/openhands-agent/secrets/.env"
    echo "   chmod 600 /srv/openhands-agent/secrets/.env"
fi

echo ""
echo "Каталоги подготовлены:"
ls -la "${BASE}/"
