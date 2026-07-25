#!/bin/bash
# OpenHands Agent Canvas — запуск
set -euo pipefail

COMPOSE_DIR="/srv/openhands-agent"
ENV_FILE="$COMPOSE_DIR/secrets/.env"

cd "$COMPOSE_DIR"
echo "=== OpenHands Agent Canvas — запуск ==="

if [ ! -f "$ENV_FILE" ]; then
    echo "ОШИБКА: $ENV_FILE не найден."
    exit 1
fi

if [ "$(stat -c '%a' "$ENV_FILE")" != "600" ]; then
    echo "ОШИБКА: права $ENV_FILE должны быть 600."
    exit 1
fi

API_KEY="$(sed -n 's/^LOCAL_BACKEND_API_KEY=//p' "$ENV_FILE" | head -n 1)"
if [ -z "$API_KEY" ] || [ "$API_KEY" = "your-generated-key-here" ]; then
    echo "ОШИБКА: LOCAL_BACKEND_API_KEY не задан или оставлен шаблонным."
    exit 1
fi
unset API_KEY

mkdir -p config workspace logs

docker compose config >/dev/null
docker compose up -d

echo ""
echo "Статус:"
docker compose ps
echo ""
echo "Доступ: http://10.77.0.2:8000/canvas (через WireGuard)"
