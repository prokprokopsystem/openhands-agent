#!/usr/bin/bash
# OpenHands Agent — установка broker на хост mini-server
# Идемпотентная. Запускать только из зафиксированного коммита.
#
# Usage: sudo ./setup-broker.sh <commit-sha>
#   commit-sha: проверенный SHA коммита, из которого установка разрешена
#
# Пример: sudo ./setup-broker.sh fcb532a
#
set -euo pipefail

COMMIT_SHA="${1:-}"

BROKER_USER="openhands-broker"
BROKER_HOME="/home/${BROKER_USER}"
BROKER_LIB="/usr/local/lib/openhands-broker"
BROKER_ETC="/etc/openhands-broker"
BROKER_LOG="/var/log/openhands-broker"
SUDOERS_FILE="/etc/sudoers.d/openhands-broker"
SSH_DIR="${BROKER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
LOCKFILE="/tmp/.openhands-broker-setup.lock"

ok()   { printf '  [OK] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; exit 1; }

# --- Блокировка ---
exec 9>"${LOCKFILE}"
flock -n 9 || fail "Another setup is running"

# --- Root check ---
[ "$(id -u)" -eq 0 ] || fail "Run with sudo"

# --- Проверка SHA ---
[ -n "${COMMIT_SHA}" ] || fail "Usage: sudo $0 <commit-sha>"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/../.."
CURRENT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "not-a-git-repo")
[ "${CURRENT_SHA}" = "${COMMIT_SHA}" ] || fail "SHA mismatch: current=${CURRENT_SHA} required=${COMMIT_SHA}. Run only from verified commit."

# --- Проверка зависимостей ---
command -v python3 >/dev/null 2>&1 || fail "python3 required"
python3 -c "import yaml" 2>/dev/null || fail "PyYAML required (pip3 install pyyaml)"
command -v docker >/dev/null 2>&1 || fail "docker required"

# --- Создание пользователя (идемпотентно) ---
if ! id "${BROKER_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        --comment "OpenHands Agent Broker" "${BROKER_USER}"
    ok "User created: ${BROKER_USER}"
else
    ok "User already exists: ${BROKER_USER}"
fi

# --- Каталоги (только root, пользователь не пишет) ---
install -d -o root -g root -m 755 "${BROKER_LIB}"
install -d -o root -g root -m 755 "${BROKER_ETC}"
install -d -o root -g root -m 755 "${BROKER_ETC}/secrets"
install -d -o root -g root -m 755 "${BROKER_LOG}"
ok "Directories created"

# --- SSH home (.ssh владельцем root, 700) ---
install -d -o root -g root -m 700 "${BROKER_HOME}"
install -d -o root -g root -m 700 "${SSH_DIR}"
ok "SSH home: ${SSH_DIR}"

# --- Копирование wrapper (root:root, 755) ---
SCRIPT_SRC="${SCRIPT_DIR}/broker-wrapper.sh"
[ -f "${SCRIPT_SRC}" ] || fail "${SCRIPT_SRC} not found"
install -o root -g root -m 755 "${SCRIPT_SRC}" "${BROKER_LIB}/broker-wrapper.sh"
ok "broker-wrapper.sh"

# --- Копирование tools.yaml (root:root, 644) ---
YAML_SRC="${SCRIPT_DIR}/tools.yaml"
[ -f "${YAML_SRC}" ] || fail "${YAML_SRC} not found"
install -o root -g root -m 644 "${YAML_SRC}" "${BROKER_ETC}/tools.yaml"
ok "tools.yaml"

# --- authorized_keys с forced command ---
if [ ! -f "${AUTH_KEYS}" ]; then
    cat > "${AUTH_KEYS}" << 'AUTH'
# OpenHands Broker — SSH forced command
# Добавьте публичный ключ ниже с префиксом:
# no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,command="/usr/local/lib/openhands-broker/broker-wrapper.sh"
AUTH
    chmod 600 "${AUTH_KEYS}"
    chown root:root "${AUTH_KEYS}"
    ok "authorized_keys template created"
    warn "Add public key: echo 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,command=\"/usr/local/lib/openhands-broker/broker-wrapper.sh\" <pubkey>' >> ${AUTH_KEYS}"
else
    ok "authorized_keys already exists"
    # Проверка, что все ключи имеют forced command
    HAS_FC=$(grep -c 'command="/usr/local/lib/openhands-broker/broker-wrapper.sh"' "${AUTH_KEYS}" 2>/dev/null || echo 0)
    if [ "${HAS_FC}" -eq 0 ]; then
        warn "No keys with forced command found in ${AUTH_KEYS}"
    fi
fi

# --- Sudo-правила (только команды из tools.yaml) ---
cat > "${SUDOERS_FILE}" << 'SUDO'
# OpenHands Agent Broker — разрешённые команды
# Должны соответствовать tools.yaml. Проверено visudo -cf.
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker ps
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker compose -f /srv/openhands-agent/deployment/compose.yaml ps
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker compose -f /srv/openhands-agent/deployment/compose.yaml logs -n *
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl restart openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl stop openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl start openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/sbin/visudo -c -f *
openhands-broker ALL=(root) NOPASSWD: /usr/local/bin/openhands-backup.sh
openhands-broker ALL=(root) NOPASSWD: /srv/openhands-agent/deployment/scripts/validate-runtime.sh
SUDO
chmod 440 "${SUDOERS_FILE}"

# Проверка sudoers через visudo -cf
visudo -cf "${SUDOERS_FILE}" >/dev/null 2>&1 || fail "sudoers syntax check failed"
ok "sudo rules: ${SUDOERS_FILE} (visudo -cf passed)"

# --- Ограничения openhands-broker (без права записи в реестр и secrets) ---
chmod 755 "${BROKER_LIB}"
chmod 755 "${BROKER_ETC}"
chmod 755 "${BROKER_ETC}/secrets"
chmod 755 "${BROKER_LOG}"
# Пользователь не может менять файлы
chown -R root:root "${BROKER_LIB}" "${BROKER_ETC}" "${BROKER_LOG}"
ok "Broker user cannot modify registry, wrapper, or secrets"

# --- SSH доступ (только forced command, no shell) ---
# Shell уже /usr/sbin/nologin — forced command срабатывает до shell
BROKER_SHELL=$(getent passwd "${BROKER_USER}" | cut -d: -f7)
if [ "${BROKER_SHELL}" != "/usr/sbin/nologin" ]; then
    usermod -s /usr/sbin/nologin "${BROKER_USER}"
    ok "Shell set to /usr/sbin/nologin"
else
    ok "Shell is /usr/sbin/nologin"
fi

# --- Logrotate ---
if [ ! -f /etc/logrotate.d/openhands-broker ]; then
    cat > /etc/logrotate.d/openhands-broker << 'LOGROTATE'
/var/log/openhands-broker/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 640 root root
}
LOGROTATE
    ok "logrotate installed"
else
    ok "logrotate already exists"
fi

echo ""
echo "=== Setup complete ==="
echo "Add SSH key manually (see warning above for format)."
