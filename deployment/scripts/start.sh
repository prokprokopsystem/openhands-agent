#!/usr/bin/bash
# OpenHands Agent Canvas — запуск (оболочка над systemd)
# Главный lifecycle: systemd (deployment/systemd/openhands-agent.service)
set -euo pipefail

echo "=== OpenHands Agent Canvas — запуск через systemd ==="

# Runtime-проверка
/usr/bin/bash /srv/openhands-agent/deployment/scripts/validate-runtime.sh

echo ""
echo "Запуск openhands-agent.service..."
sudo systemctl start openhands-agent.service

sleep 3
echo ""
systemctl status openhands-agent.service --no-pager -l || true

echo ""
echo 'Доступ: http://10.77.0.2:8000/canvas (только WireGuard)'
