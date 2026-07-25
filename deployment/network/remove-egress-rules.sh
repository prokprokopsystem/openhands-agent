#!/bin/bash
# Удалить egress-правила OpenHands (10.89.0.0/28)
# Требует sudo. Удаляет ТОЛЬКО правила OpenHands.
set -e

SUBNET="10.89.0.0/28"
CHAIN="DOCKER-USER"

echo "=== Удаление egress-правил для ${SUBNET} ==="

# Удалить все правила DOCKER-USER с этим subnet
while iptables -L ${CHAIN} -n 2>/dev/null | grep -q "${SUBNET}"; do
    LINE=$(iptables -L ${CHAIN} -n --line-numbers 2>/dev/null | grep "${SUBNET}" | head -1 | awk '{print $1}')
    if [ -n "${LINE}" ]; then
        iptables -D ${CHAIN} "${LINE}" 2>/dev/null || break
    else
        break
    fi
done

echo "Правила удалены."
echo "Проверка: iptables -L ${CHAIN} -n | grep ${SUBNET}"
sudo iptables -L ${CHAIN} -n 2>/dev/null | grep "${SUBNET}" && echo "(остались правила!)" || echo "чисто"
