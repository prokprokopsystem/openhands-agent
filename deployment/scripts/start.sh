#!/bin/bash
# OpenHands Agent Canvas — запуск
set -e

COMPOSE_DIR="/srv/openhands-agent"
cd "$COMPOSE_DIR"

echo "=== OpenHands Agent Canvas — запуск ==="

# Проверка .env
if [ ! -f secrets/.env ]; then
    echo "ОШИБКА: secrets/.env не найден. Создайте из .env.example"
    exit 1
fi

if ! grep -q "LOCAL_BACKEND_API_KEY=" secrets/.env; then
    echo "ОШИБКА: LOCAL_BACKEND_API_KEY не задан в secrets/.env"
    exit 1
fi

# Проверка каталогов
mkdir -p config workspace logs

# Запуск
docker compose up -d

sleep 3
echo ""
echo "Статус:"
docker compose ps
echo ""
echo "Доступ: http://10.77.0.2:8000/canvas (через WireGuard)"
