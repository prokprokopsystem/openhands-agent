#!/bin/bash
# OpenHands Agent Canvas — запуск
set -e

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
cd "${BASE}"

echo "=== OpenHands Agent Canvas — запуск ==="

# Проверка прав
if [ ! -f secrets/.env ]; then
    echo "❌ ОШИБКА: secrets/.env не найден. Создайте из .env.example"
    exit 1
fi

PERMS=$(stat -c "%a" secrets/.env 2>/dev/null || echo "000")
if [ "${PERMS}" != "600" ]; then
    echo "❌ ОШИБКА: secrets/.env права ${PERMS}, должно быть 600"
    exit 1
fi

if ! grep -q 'LOCAL_BACKEND_API_KEY' secrets/.env 2>/dev/null; then
    echo "⚠️  LOCAL_BACKEND_API_KEY не задан в secrets/.env"
fi

# Проверка каталогов
for d in config test-workspace secrets logs; do
    if [ ! -d "${BASE}/${d}" ]; then
        echo "❌ ОШИБКА: каталог ${BASE}/${d} не существует. Запустите prepare.sh"
        exit 1
    fi
done

# Проверка WireGuard
if ! ip addr show wg0 2>/dev/null | grep -q "10.77.0.2"; then
    echo "❌ ОШИБКА: адрес 10.77.0.2 не найден на wg0"
    exit 1
fi

echo "✅ Проверки пройдены."

# Compose config (без секретов)
echo ""
echo "--- docker compose config ---"
docker compose -f "${COMPOSE_FILE}" config 2>&1 | grep -v "LOCAL_BACKEND_API_KEY" || true

# Запуск
echo ""
docker compose -f "${COMPOSE_FILE}" up -d

sleep 5
echo ""
echo "Статус:"
docker compose -f "${COMPOSE_FILE}" ps

echo ""
echo 'Доступ: http://10.77.0.2:8000/canvas (только WireGuard)'
