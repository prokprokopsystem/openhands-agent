#!/usr/bin/bash
# OpenHands Agent Canvas — остановка (оболочка над systemd)
set -euo pipefail

echo "=== OpenHands Agent Canvas — остановка через systemd ==="

sudo systemctl stop openhands-agent.service

sleep 2

# Проверка: контейнер остановлен
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'openhands-agent'; then
    echo "⚠️  Контейнер ещё работает"
else
    echo "✅ Контейнер остановлен"
fi

# Проверка: firewall-цепочки удалены
if iptables -nL OPENHANDS-EGRESS >/dev/null 2>&1; then
    echo "⚠️  Цепочка OPENHANDS-EGRESS всё ещё существует"
else
    echo "✅ Firewall-цепочки удалены"
fi

echo ""
echo "Состояние сохранено: /srv/openhands-agent/config/"
echo "Workspace сохранён: /srv/openhands-agent/test-workspace/"
