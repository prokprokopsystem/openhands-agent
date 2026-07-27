#!/usr/bin/bash
# OpenHands Agent — полное удаление broker с хоста
# Идемпотентная. Не затрагивает чужие данные.
#
# Usage: sudo ./purge-broker.sh [--confirm]
#
set -euo pipefail

BROKER_USER="openhands-broker"
CONFIRM="${1:-}"

ok()   { printf '  [OK] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run with sudo"

if [ "${CONFIRM}" != "--confirm" ]; then
    echo ""
    echo "WARNING: This will remove all broker components:"
    echo "  - User: ${BROKER_USER}"
    echo "  - Home: /home/${BROKER_USER}/"
    echo "  - Lib:  /usr/local/lib/openhands-broker/"
    echo "  - Config: /etc/openhands-broker/"
    echo "  - Logs: /var/log/openhands-broker/"
    echo "  - Sudoers: /etc/sudoers.d/openhands-broker"
    echo "  - Logrotate: /etc/logrotate.d/openhands-broker"
    echo ""
    echo "Run with --confirm to proceed: sudo $0 --confirm"
    exit 0
fi

# --- Удаление sudoers ---
if [ -f /etc/sudoers.d/openhands-broker ]; then
    rm -f /etc/sudoers.d/openhands-broker
    ok "sudoers removed"
else
    ok "sudoers not found"
fi

# --- Удаление logrotate ---
if [ -f /etc/logrotate.d/openhands-broker ]; then
    rm -f /etc/logrotate.d/openhands-broker
    ok "logrotate removed"
else
    ok "logrotate not found"
fi

# --- Удаление пользователя (включая home) ---
if id "${BROKER_USER}" &>/dev/null; then
    userdel -r "${BROKER_USER}" 2>/dev/null || userdel "${BROKER_USER}" 2>/dev/null || true
    ok "User ${BROKER_USER} removed"
else
    ok "User ${BROKER_USER} not found"
fi

# --- Удаление каталогов (на случай если userdel -r не удалил) ---
for dir in /home/${BROKER_USER} /usr/local/lib/openhands-broker /etc/openhands-broker /var/log/openhands-broker; do
    if [ -d "${dir}" ]; then
        rm -rf "${dir}"
        ok "Removed ${dir}"
    fi
done

# --- Очистка lockfile ---
rm -f /tmp/.openhands-broker-setup.lock

echo ""
echo "=== Purge complete ==="