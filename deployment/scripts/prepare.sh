#!/bin/bash
# OpenHands Agent Canvas — подготовка каталогов
# Запускать на mini-server: sudo bash prepare.sh
# НЕ запускает контейнер, только создаёт каталоги и права.
set -e

BASE="/srv/openhands-agent"
OWNER="igor:igor"

echo "=== OpenHands Agent Canvas — подготовка каталогов ==="

# Создание
sudo mkdir -p "${BASE}/config"
sudo mkdir -p "${BASE}/test-workspace"
sudo mkdir -p "${BASE}/secrets"
sudo mkdir -p "${BASE}/logs"

# Права: config и secrets — только владелец
sudo chmod 700 "${BASE}/config"
sudo chmod 700 "${BASE}/secrets"
sudo chmod 755 "${BASE}/test-workspace"
sudo chmod 755 "${BASE}/logs"

# Владелец
sudo chown -R "${OWNER}" "${BASE}"

# .env — если существует
if [ -f "${BASE}/secrets/.env" ]; then
    sudo chmod 600 "${BASE}/secrets/.env"
    sudo chown "${OWNER}" "${BASE}/secrets/.env"
    echo "secrets/.env — права 600"
else
    echo "⚠️  secrets/.env ещё не создан. Создайте из .env.example"
fi

echo ""
echo "Каталоги подготовлены:"
ls -la "${BASE}/"
echo ""
echo "Следующий шаг: создайте secrets/.env с LOCAL_BACKEND_API_KEY"
echo "Затем: bash deployment/scripts/start.sh"
