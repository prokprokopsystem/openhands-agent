#!/bin/bash
# Применить egress-правила для подсети OpenHands (10.89.0.0/28)
# Требует sudo. Не затрагивает другие контейнеры.
set -e

SUBNET="10.89.0.0/28"
CHAIN="DOCKER-USER"

echo "=== Применение egress-правил для ${SUBNET} ==="

# Разрешить DNS
iptables -I ${CHAIN} -s ${SUBNET} -p udp --dport 53 -j RETURN 2>/dev/null || true
iptables -I ${CHAIN} -s ${SUBNET} -p tcp --dport 53 -j RETURN 2>/dev/null || true

# Разрешить исходящий HTTPS
iptables -I ${CHAIN} -s ${SUBNET} -p tcp --dport 443 -j RETURN 2>/dev/null || true
iptables -I ${CHAIN} -s ${SUBNET} -p tcp --dport 80 -j RETURN 2>/dev/null || true

# Запретить internal (10.0.0.0/8), LAN (192.168.0.0/16), Docker (172.16.0.0/12)
iptables -I ${CHAIN} -s ${SUBNET} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
iptables -I ${CHAIN} -s ${SUBNET} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
iptables -I ${CHAIN} -s ${SUBNET} -d 172.16.0.0/12 -j DROP 2>/dev/null || true

echo "Правила применены."
echo "Проверка: sudo iptables -L ${CHAIN} -n -v | grep ${SUBNET}"
sudo iptables -L ${CHAIN} -n -v 2>/dev/null | grep "${SUBNET}" || echo "(правила в DOCKER-USER)"
