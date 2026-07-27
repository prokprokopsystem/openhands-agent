#!/usr/bin/bash
# OpenHands Agent — установка broker на хост mini-server
# Запускать на mini-server. Проверяет, создаёт, копирует.
#
# Usage: sudo ./setup-broker.sh [--force]
#
set -euo pipefail

BROKER_USER="openhands-broker"
BROKER_HOME="/home/${BROKER_USER}"
BROKER_LIB="/usr/local/lib/openhands-broker"
BROKER_ETC="/etc/openhands-broker"
BROKER_LOG="/var/log/openhands-broker"
SUDOERS_FILE="/etc/sudoers.d/openhands-broker"
SSH_DIR="${BROKER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

FORCE="${1:-}"

ok()   { printf '  [OK] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; exit 1; }
info() { printf '  [INFO] %s\n' "$1"; }

# --- Проверка ---
[ "$(id -u)" -eq 0 ] || fail "Запустите с sudo"

# --- Создание пользователя ---
if id "${BROKER_USER}" &>/dev/null; then
    if [ "${FORCE}" = "--force" ]; then
        warn "Пользователь ${BROKER_USER} уже существует — продолжаем (--force)"
    else
        ok "Пользователь ${BROKER_USER} уже существует"
    fi
else
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        --comment "OpenHands Agent Broker" "${BROKER_USER}"
    ok "Создан пользователь ${BROKER_USER}"
fi

# --- Каталоги ---
for dir in "${BROKER_LIB}" "${BROKER_ETC}/secrets" "${BROKER_LOG}" "${SSH_DIR}"; do
    install -d -o "${BROKER_USER}" -g "${BROKER_USER}" -m 755 "${dir}"
    ok "Каталог ${dir}"
done
chmod 700 "${SSH_DIR}"
ok "SSH_DIR: 700"

# --- Копирование wrapper ---
SCRIPT_SRC="$(dirname "$0")/broker-wrapper.sh"
if [ -f "${SCRIPT_SRC}" ]; then
    install -o root -g root -m 755 "${SCRIPT_SRC}" "${BROKER_LIB}/broker-wrapper.sh"
    ok "broker-wrapper.sh"
else
    fail "${SCRIPT_SRC} не найден"
fi

# --- Копирование tools.yaml ---
YAML_SRC="$(dirname "$0")/tools.yaml"
if [ -f "${YAML_SRC}" ]; then
    install -o root -g "${BROKER_USER}" -m 644 "${YAML_SRC}" "${BROKER_ETC}/tools.yaml"
    ok "tools.yaml"
else
    fail "${YAML_SRC} не найден"
fi

# --- Sudo-правила ---
cat > "${SUDOERS_FILE}" << 'SUDO'
# OpenHands Agent Broker — разрешённые команды
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl restart openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl stop openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl start openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl status openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/local/bin/openhands-backup.sh
openhands-broker ALL=(root) NOPASSWD: /srv/openhands-agent/deployment/scripts/validate-runtime.sh
SUDO
chmod 440 "${SUDOERS_FILE}"
ok "sudo-правила: ${SUDOERS_FILE}"

# --- SSH authorised_keys (ожидается публичный ключ) ---
# Ключ нужно добавить вручную или через --pubkey
if [ -f "${AUTH_KEYS}" ] && [ -s "${AUTH_KEYS}" ]; then
    ok "authorized_keys существует (${AUTH_KEYS})"
else
    warn "authorized_keys пуст. Добавьте публичный ключ:"
    echo "  echo '<публичный-ключ>' | sudo tee -a ${AUTH_KEYS}"
    echo "  sudo chmod 600 ${AUTH_KEYS}"
fi

# --- Logrotate ---
LOG_ROTATE="/etc/logrotate.d/openhands-broker"
if [ ! -f "${LOG_ROTATE}" ]; then
    cat > "${LOG_ROTATE}" << 'LOGROTATE'
/var/log/openhands-broker/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROTATE
    ok "logrotate: ${LOG_ROTATE}"
fi

# --- Проверка зависимостей ---
for cmd in yq python3; do
    if command -v "${cmd}" &>/dev/null; then
        ok "${cmd} доступен"
        break  # Достаточно одного
    fi
done || {
    # python3 есть всегда, PyYAML может не быть
    if python3 -c "import yaml" 2>/dev/null; then
        ok "python3 + PyYAML"
    else
        warn "PyYAML не установлен. Установите: pip3 install pyyaml"
    fi
}

echo ""
echo "=== Setup complete ==="
echo ""
echo "Добавьте публичный SSH-ключ:"
echo "  echo '<pubkey>' | sudo tee -a ${AUTH_KEYS}"
echo "  sudo chmod 600 ${AUTH_KEYS}"
echo ""
echo "Проверка:"
echo "  sudo -u ${BROKER_USER} ssh localhost ping"
echo "  echo 'system_status' | sudo -u ${BROKER_USER} ssh localhost -T"
echo ""
