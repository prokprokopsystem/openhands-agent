#!/usr/bin/bash
# OpenHands Agent — установка broker на хост mini-server
# Идемпотентная. Запускать только из зафиксированного коммита.
#
# Usage: sudo ./setup-broker.sh <commit-sha> <broker-public-key-file>
#   commit-sha: проверенный SHA коммита, из которого установка разрешена
#
# Пример: sudo ./setup-broker.sh "$(git rev-parse HEAD)" /path/to/broker-mini-server.key.pub
#
set -euo pipefail

COMMIT_SHA="${1:-}"
PUBLIC_KEY_FILE="${2:-}"

BROKER_USER="openhands-broker"
BROKER_HOME="/home/${BROKER_USER}"
BROKER_LIB="/usr/local/lib/openhands-broker"
BROKER_ETC="/etc/openhands-broker"
SUDOERS_FILE="/etc/sudoers.d/openhands-broker"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-openhands-broker.conf"
SSH_DIR="${BROKER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
CLIENT_KEY="/srv/openhands-agent/secrets/broker-mini-server.key"
LOCK_DIR="/run/lock/openhands-broker"
LOCKFILE="${LOCK_DIR}/setup.lock"

ok()   { printf '  [OK] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; exit 1; }

# --- Root check ---
[ "$(id -u)" -eq 0 ] || fail "Run with sudo"

# --- Блокировка ---
install -d -o root -g root -m 755 "${LOCK_DIR}"
exec 9>"${LOCKFILE}"
flock -n 9 || fail "Another setup is running"

# --- Проверка SHA ---
[ -n "${COMMIT_SHA}" ] && [ -n "${PUBLIC_KEY_FILE}" ] \
    || fail "Usage: sudo $0 <commit-sha> <broker-public-key-file>"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/../.."
[[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "A full 40-character commit SHA is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Installation source is not a Git worktree"
CURRENT_SHA="$(git rev-parse HEAD)"
[ "${CURRENT_SHA}" = "${COMMIT_SHA}" ] || fail "SHA mismatch: current=${CURRENT_SHA} required=${COMMIT_SHA}. Run only from verified commit."
git diff --quiet --ignore-submodules HEAD -- || fail "Installation source has modified tracked files"
git diff --cached --quiet --ignore-submodules HEAD -- || fail "Installation source has staged changes"
[ -z "$(git ls-files --others --exclude-standard)" ] \
    || fail "Installation source has untracked files"
for source_path in \
    deployment/broker/setup-broker.sh \
    deployment/broker/broker-wrapper.sh \
    deployment/broker/tools.yaml; do
    git ls-files --error-unmatch "${source_path}" >/dev/null 2>&1 \
        || fail "Untracked installation source: ${source_path}"
    [ "$(git hash-object "${source_path}")" = "$(git rev-parse "${COMMIT_SHA}:${source_path}")" ] \
        || fail "Installation source does not match commit: ${source_path}"
done

# --- Проверка зависимостей ---
command -v python3 >/dev/null 2>&1 || fail "python3 required"
python3 -c "import yaml" 2>/dev/null || fail "PyYAML required (pip3 install pyyaml)"
command -v docker >/dev/null 2>&1 || fail "docker required"
command -v logger >/dev/null 2>&1 || fail "logger required for fail-closed audit"
command -v visudo >/dev/null 2>&1 || fail "visudo required"
command -v sshd >/dev/null 2>&1 || fail "sshd required"
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen required"
logger -p authpriv.notice -t openhands-broker-setup -- '{"status":"AUDIT_PREFLIGHT"}' \
    || fail "journald audit transport unavailable"

# --- Проверка ключей до любых изменений системы ---
[ -f "${PUBLIC_KEY_FILE}" ] || fail "Broker public key not found: ${PUBLIC_KEY_FILE}"
[ "$(grep -cEv '^[[:space:]]*$' "${PUBLIC_KEY_FILE}")" -eq 1 ] \
    || fail "Broker public key file must contain exactly one key"
ssh-keygen -l -f "${PUBLIC_KEY_FILE}" >/dev/null 2>&1 || fail "Invalid broker public key"
PUBLIC_KEY="$(awk 'NF { print $1 " " $2; exit }' "${PUBLIC_KEY_FILE}")"
[[ "${PUBLIC_KEY}" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256)[[:space:]][A-Za-z0-9+/=]+$ ]] \
    || fail "Unsupported broker public key type"
[ -f "${CLIENT_KEY}" ] || fail "Broker private key not found: ${CLIENT_KEY}"

# --- Создание пользователя (идемпотентно) ---
if ! id "${BROKER_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /bin/bash \
        --comment "OpenHands Agent Broker" "${BROKER_USER}"
    ok "User created: ${BROKER_USER}"
else
    ok "User already exists: ${BROKER_USER}"
fi

# --- Каталоги (только root, пользователь не пишет) ---
install -d -o root -g root -m 755 "${BROKER_LIB}"
install -d -o root -g root -m 755 "${BROKER_ETC}"
install -d -o root -g root -m 755 "${BROKER_ETC}/secrets"
ok "Directories created"

# Контейнер работает как 10001:10001. Ключ доступен только root и этой группе.
chown root:10001 "${CLIENT_KEY}"
chmod 0640 "${CLIENT_KEY}"
[ "$(stat -c '%u:%g:%a' "${CLIENT_KEY}")" = "0:10001:640" ] \
    || fail "Broker private key permissions are not root:10001 0640"
ok "Broker client key permissions: root:10001 0640"

# --- SSH home: root-controlled, broker может только пройти к authorized_keys ---
install -d -o root -g root -m 711 "${BROKER_HOME}"
install -d -o root -g root -m 711 "${SSH_DIR}"
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

# --- authorized_keys: ровно один ключ с закрытыми ограничениями ---
AUTH_KEYS_TMP="$(mktemp "${SSH_DIR}/.authorized_keys.XXXXXX")"
printf '%s %s\n' \
    'from="10.89.0.2",restrict,command="/usr/local/lib/openhands-broker/broker-wrapper.sh"' \
    "${PUBLIC_KEY}" > "${AUTH_KEYS_TMP}"
chown root:"${BROKER_USER}" "${AUTH_KEYS_TMP}"
chmod 440 "${AUTH_KEYS_TMP}"
mv -f "${AUTH_KEYS_TMP}" "${AUTH_KEYS}"
ok "authorized_keys installed with source restriction and forced command"

# --- Sudo-правила: проверка временного файла, затем atomic install ---
SUDOERS_TMP="$(mktemp /etc/sudoers.d/.openhands-broker.XXXXXX)"
trap 'rm -f "${SUDOERS_TMP:-}" "${SSHD_CANDIDATE:-}" "${SSHD_TMP:-}" "${SSHD_OLD:-}"' EXIT
cat > "${SUDOERS_TMP}" << 'SUDO'
# OpenHands Agent Broker — разрешённые команды
# Должны соответствовать tools.yaml. Проверено visudo -cf.
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker ps
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker compose -f /srv/openhands-agent/deployment/compose.yaml ps
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker compose -f /srv/openhands-agent/deployment/compose.yaml logs -n *
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl restart openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl stop openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/bin/systemctl start openhands-agent.service
openhands-broker ALL=(root) NOPASSWD: /usr/local/bin/openhands-backup.sh
openhands-broker ALL=(root) NOPASSWD: /srv/openhands-agent/deployment/scripts/validate-runtime.sh
SUDO
chown root:root "${SUDOERS_TMP}"
chmod 440 "${SUDOERS_TMP}"
visudo -cf "${SUDOERS_TMP}" >/dev/null 2>&1 || fail "sudoers syntax check failed"
mv -f "${SUDOERS_TMP}" "${SUDOERS_FILE}"
SUDOERS_TMP=""
ok "sudo rules installed atomically: ${SUDOERS_FILE}"

# --- Ограничения openhands-broker (без права записи в реестр и secrets) ---
chmod 755 "${BROKER_LIB}"
chmod 755 "${BROKER_ETC}"
chmod 755 "${BROKER_ETC}/secrets"
# Пользователь не может менять файлы
chown -R root:root "${BROKER_LIB}" "${BROKER_ETC}"
ok "Broker user cannot modify registry, wrapper, or secrets"

# --- SSH доступ (обычный shell нужен sshd для запуска forced command) ---
BROKER_SHELL=$(getent passwd "${BROKER_USER}" | cut -d: -f7)
if [ "${BROKER_SHELL}" != "/bin/bash" ]; then
    usermod -s /bin/bash "${BROKER_USER}"
    ok "Shell set to /bin/bash"
else
    ok "Shell is /bin/bash"
fi
# Непригодный для password login marker без "!": OpenSSH не считает account locked.
usermod -p '*NP*' "${BROKER_USER}"

# --- sshd defense-in-depth: forced command действует для любого ключа пользователя ---
SSHD_TMP="$(mktemp /run/openhands-broker-sshd.XXXXXX)"
cat > "${SSHD_TMP}" << 'SSHD'
Match User openhands-broker
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForceCommand /usr/local/lib/openhands-broker/broker-wrapper.sh
    DisableForwarding yes
    PermitTTY no
    PermitUserRC no
SSHD
chmod 600 "${SSHD_TMP}"

# Проверяем candidate вместе с основной конфигурацией до установки drop-in.
SSHD_CANDIDATE="$(mktemp /run/openhands-broker-sshd-candidate.XXXXXX)"
cat /etc/ssh/sshd_config > "${SSHD_CANDIDATE}"
cat "${SSHD_TMP}" >> "${SSHD_CANDIDATE}"
sshd -t -f "${SSHD_CANDIDATE}" || fail "sshd candidate configuration is invalid"

install -d -o root -g root -m 755 /etc/ssh/sshd_config.d
SSHD_OLD="$(mktemp /run/openhands-broker-sshd-old.XXXXXX)"
SSHD_HAD_OLD=false
if [ -f "${SSHD_DROPIN}" ]; then
    cp -a "${SSHD_DROPIN}" "${SSHD_OLD}"
    SSHD_HAD_OLD=true
fi
install -o root -g root -m 600 "${SSHD_TMP}" "${SSHD_DROPIN}.new"
mv -f "${SSHD_DROPIN}.new" "${SSHD_DROPIN}"
if ! sshd -t; then
    if [ "${SSHD_HAD_OLD}" = true ]; then
        install -o root -g root -m 600 "${SSHD_OLD}" "${SSHD_DROPIN}"
    else
        rm -f "${SSHD_DROPIN}"
    fi
    fail "installed sshd configuration is invalid; previous policy restored"
fi
if ! systemctl reload ssh.service; then
    if [ "${SSHD_HAD_OLD}" = true ]; then
        install -o root -g root -m 600 "${SSHD_OLD}" "${SSHD_DROPIN}"
    else
        rm -f "${SSHD_DROPIN}"
    fi
    sshd -t && systemctl reload ssh.service || true
    fail "failed to reload ssh.service; previous policy restored"
fi
ok "sshd forced-command policy installed and reloaded"

# Audit идёт в journald. Проверяем транспорт до объявления установки успешной.
logger -p authpriv.notice -t openhands-broker-setup -- '{"status":"AUDIT_READY"}' \
    || fail "journald audit transport unavailable"
ok "fail-closed journald audit is available"

rm -f "${SSHD_TMP}" "${SSHD_CANDIDATE}" "${SSHD_OLD}"
SSHD_TMP=""
SSHD_CANDIDATE=""
SSHD_OLD=""
trap - EXIT

echo ""
echo "=== Setup complete ==="
echo "Broker key, sudoers, sshd forced command, and journald audit are configured."
