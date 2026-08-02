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
CLIENT_KNOWN_HOSTS="${BROKER_ETC}/client_known_hosts"
HOST_KEY_PRIVATE="/etc/ssh/ssh_host_ed25519_key"
HOST_KEY_PUBLIC="/etc/ssh/ssh_host_ed25519_key.pub"
BROKER_HOST="10.89.0.1"
BROKER_PORT="22"
COMPOSE_TARGET="/srv/openhands-agent/deployment/compose.yaml"
PREPARE_TARGET="/srv/openhands-agent/deployment/scripts/prepare.sh"
VALIDATE_RUNTIME_TARGET="/srv/openhands-agent/deployment/scripts/validate-runtime.sh"
SEED_CONFIG_TARGET="/srv/openhands-agent/deployment/scripts/seed-config.sh"
SETTINGS_TEMPLATE_TARGET="/srv/openhands-agent/deployment/config/settings.json"
DEEPSEEK_TEMPLATE_TARGET="/srv/openhands-agent/deployment/config/profiles/deepseek-chat.json"
DEFAULT_AGENT_TEMPLATE_TARGET="/srv/openhands-agent/deployment/config/agent-profiles/default.json"
AUTHORIZED_PREVIOUS_COMPOSE_HASH="957995f428b050c5a41dea0926ea2140d0bf29fa"
AUTHORIZED_PREVIOUS_PREPARE_HASHES=(
    "77cece874846d56b058a9f0932f8188674ec11c3"
    "cef49e202f8bfc0450e882721a8bb6ad88cd5aff"
    "6835ee74594890cfb66bca9d4ddcdb1b14baf3ec"
)
AUTHORIZED_PREVIOUS_VALIDATE_RUNTIME_HASHES=(
    "11707aa434ceb324dec704b3e47374604a2f45c6"
    "664a64f0be8647de8e3b5d79a56e18644b8c5926"
)
LOCK_DIR="/run/lock/openhands-broker"
LOCKFILE="${LOCK_DIR}/setup.lock"
HOST_SCAN_TMP=""
KNOWN_HOSTS_TMP=""
COMPOSE_TMP=""
PREPARE_TMP=""
VALIDATE_RUNTIME_TMP=""
SEED_CONFIG_TMP=""
SETTINGS_TEMPLATE_TMP=""
DEEPSEEK_TEMPLATE_TMP=""
DEFAULT_AGENT_TEMPLATE_TMP=""
SUDOERS_TMP=""
SSHD_CANDIDATE=""
SSHD_TMP=""
SSHD_OLD=""

ok()   { printf '  [OK] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; exit 1; }

require_authorized_runtime_target() {
    local source_path="$1" target_path="$2" label="$3"
    local source_hash target_hash allowed_hash
    shift 3
    [ -f "${target_path}" ] || fail "Runtime ${label} target not found: ${target_path}"
    source_hash="$(git hash-object "${source_path}")"
    target_hash="$(git hash-object "${target_path}")"
    [ "${target_hash}" = "${source_hash}" ] && return 0
    for allowed_hash in "$@"; do
        [ "${target_hash}" = "${allowed_hash}" ] && return 0
    done
    fail "Runtime ${label} diverges from every authorized update base"
}

require_absent_or_current_runtime_target() {
    local source_path="$1" target_path="$2" label="$3"
    local source_hash target_hash
    if [ ! -e "${target_path}" ] && [ ! -L "${target_path}" ]; then
        return 0
    fi
    [ -f "${target_path}" ] && [ ! -L "${target_path}" ] \
        || fail "Runtime ${label} target is not a regular file"
    source_hash="$(git hash-object "${source_path}")"
    target_hash="$(git hash-object "${target_path}")"
    [ "${target_hash}" = "${source_hash}" ] \
        || fail "Runtime ${label} diverges from the verified commit"
}

# --- Root check ---
[ "$(id -u)" -eq 0 ] || fail "Run with sudo"

cleanup() {
    rm -f "${HOST_SCAN_TMP:-}" "${KNOWN_HOSTS_TMP:-}" \
        "${COMPOSE_TMP:-}" "${PREPARE_TMP:-}" \
        "${VALIDATE_RUNTIME_TMP:-}" "${SUDOERS_TMP:-}" \
        "${SEED_CONFIG_TMP:-}" "${SETTINGS_TEMPLATE_TMP:-}" \
        "${DEEPSEEK_TEMPLATE_TMP:-}" "${DEFAULT_AGENT_TEMPLATE_TMP:-}" \
        "${SSHD_CANDIDATE:-}" "${SSHD_TMP:-}" "${SSHD_OLD:-}"
}
trap cleanup EXIT

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
    deployment/broker/journal-logs.sh \
    deployment/broker/tools.yaml \
    deployment/compose.yaml \
    deployment/scripts/prepare.sh \
    deployment/scripts/validate-runtime.sh \
    deployment/scripts/seed-config.sh \
    deployment/config/settings.json \
    deployment/config/profiles/deepseek-chat.json \
    deployment/config/agent-profiles/default.json; do
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
command -v sudo >/dev/null 2>&1 || fail "sudo required"
command -v sshd >/dev/null 2>&1 || fail "sshd required"
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen required"
command -v ssh-keyscan >/dev/null 2>&1 || fail "ssh-keyscan required"
[ -x /usr/bin/journalctl ] || fail "/usr/bin/journalctl required"
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

# --- Pin host key: local sshd key is the trust anchor; live scan is verified ---
[ -f "${HOST_KEY_PRIVATE}" ] || fail "SSH host private key not found: ${HOST_KEY_PRIVATE}"
[ -f "${HOST_KEY_PUBLIC}" ] || fail "SSH host public key not found: ${HOST_KEY_PUBLIC}"
LOCAL_HOST_KEY="$(awk 'NF >= 2 { print $1 " " $2; exit }' "${HOST_KEY_PUBLIC}")"
[[ "${LOCAL_HOST_KEY}" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+$ ]] \
    || fail "Mini-server SSH host key is not ED25519"
DERIVED_HOST_KEY="$(ssh-keygen -y -f "${HOST_KEY_PRIVATE}")"
DERIVED_HOST_FINGERPRINT="$(
    printf '%s\n' "${DERIVED_HOST_KEY}" \
        | ssh-keygen -lf - -E sha256 2>/dev/null \
        | awk 'NR == 1 {print $2}'
)"
[ -n "${DERIVED_HOST_FINGERPRINT}" ] \
    || fail "Cannot fingerprint SSH host key derived from private key"
LOCAL_HOST_FINGERPRINT="$(ssh-keygen -lf "${HOST_KEY_PUBLIC}" -E sha256 | awk 'NR == 1 {print $2}')"
[ -n "${LOCAL_HOST_FINGERPRINT}" ] || fail "Cannot fingerprint local SSH host key"
[ "${DERIVED_HOST_FINGERPRINT}" = "${LOCAL_HOST_FINGERPRINT}" ] \
    || fail "SSH host public key does not match its private key"

HOST_SCAN_TMP="$(mktemp /run/openhands-broker-host-scan.XXXXXX)"
ssh-keyscan -4 -T 5 -p "${BROKER_PORT}" -t ed25519 "${BROKER_HOST}" \
    > "${HOST_SCAN_TMP}" 2>/dev/null \
    || fail "Cannot read live ED25519 host key from ${BROKER_HOST}:${BROKER_PORT}"
mapfile -t OBSERVED_HOST_KEYS < <(
    awk '$2 == "ssh-ed25519" { print $2 " " $3 }' "${HOST_SCAN_TMP}" | sort -u
)
[ "${#OBSERVED_HOST_KEYS[@]}" -eq 1 ] \
    || fail "Expected exactly one live ED25519 host key"
OBSERVED_HOST_FINGERPRINT="$(ssh-keygen -lf "${HOST_SCAN_TMP}" -E sha256 | awk 'NR == 1 {print $2}')"
[ -n "${OBSERVED_HOST_FINGERPRINT}" ] \
    || fail "Cannot fingerprint live SSH host key"
[ "${OBSERVED_HOST_FINGERPRINT}" = "${LOCAL_HOST_FINGERPRINT}" ] \
    || fail "Live SSH host fingerprint does not match mini-server sshd host key"
rm -f "${HOST_SCAN_TMP}"
HOST_SCAN_TMP=""
ok "Pinned ED25519 host key verified for ${BROKER_HOST}:${BROKER_PORT}"

COMPOSE_SOURCE="${SCRIPT_DIR}/../compose.yaml"
PREPARE_SOURCE="${SCRIPT_DIR}/../scripts/prepare.sh"
VALIDATE_RUNTIME_SOURCE="${SCRIPT_DIR}/../scripts/validate-runtime.sh"
SEED_CONFIG_SOURCE="${SCRIPT_DIR}/../scripts/seed-config.sh"
SETTINGS_TEMPLATE_SOURCE="${SCRIPT_DIR}/../config/settings.json"
DEEPSEEK_TEMPLATE_SOURCE="${SCRIPT_DIR}/../config/profiles/deepseek-chat.json"
DEFAULT_AGENT_TEMPLATE_SOURCE="${SCRIPT_DIR}/../config/agent-profiles/default.json"
bash -n "${PREPARE_SOURCE}" || fail "prepare.sh candidate syntax is invalid"
bash -n "${VALIDATE_RUNTIME_SOURCE}" || fail "validate-runtime.sh candidate syntax is invalid"
bash -n "${SEED_CONFIG_SOURCE}" || fail "seed-config.sh candidate syntax is invalid"
require_authorized_runtime_target \
    "${COMPOSE_SOURCE}" "${COMPOSE_TARGET}" "compose.yaml" \
    "${AUTHORIZED_PREVIOUS_COMPOSE_HASH}"
require_authorized_runtime_target \
    "${PREPARE_SOURCE}" "${PREPARE_TARGET}" "prepare.sh" \
    "${AUTHORIZED_PREVIOUS_PREPARE_HASHES[@]}"
require_authorized_runtime_target \
    "${VALIDATE_RUNTIME_SOURCE}" "${VALIDATE_RUNTIME_TARGET}" "validate-runtime.sh" \
    "${AUTHORIZED_PREVIOUS_VALIDATE_RUNTIME_HASHES[@]}"
require_absent_or_current_runtime_target \
    "${SEED_CONFIG_SOURCE}" "${SEED_CONFIG_TARGET}" "seed-config.sh"
require_absent_or_current_runtime_target \
    "${SETTINGS_TEMPLATE_SOURCE}" "${SETTINGS_TEMPLATE_TARGET}" "settings template"
require_absent_or_current_runtime_target \
    "${DEEPSEEK_TEMPLATE_SOURCE}" "${DEEPSEEK_TEMPLATE_TARGET}" "DeepSeek template"
require_absent_or_current_runtime_target \
    "${DEFAULT_AGENT_TEMPLATE_SOURCE}" "${DEFAULT_AGENT_TEMPLATE_TARGET}" "default agent template"

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

# --- Узкий root helper для чтения только журнала openhands-agent ---
JOURNAL_HELPER_SRC="${SCRIPT_DIR}/journal-logs.sh"
[ -f "${JOURNAL_HELPER_SRC}" ] || fail "${JOURNAL_HELPER_SRC} not found"
install -o root -g root -m 755 \
    "${JOURNAL_HELPER_SRC}" "${BROKER_LIB}/journal-logs"
ok "journal-logs"

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
cat > "${SUDOERS_TMP}" << 'SUDO'
# OpenHands Agent Broker — разрешённые команды
# Должны соответствовать tools.yaml. Проверено visudo -cf.
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker ps
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker compose -f /srv/openhands-agent/deployment/compose.yaml ps
openhands-broker ALL=(root) NOPASSWD: /usr/bin/docker compose -f /srv/openhands-agent/deployment/compose.yaml logs -n *
openhands-broker ALL=(root) NOPASSWD: /usr/local/lib/openhands-broker/journal-logs
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

sudo -u "${BROKER_USER}" -- \
    sudo -n "${BROKER_LIB}/journal-logs" openhands-agent 1 \
    >/dev/null 2>&1 \
    || fail "journal_logs sudo rule cannot read the openhands-agent journal"
ok "journal_logs has narrow broker-controlled journal access"

# --- Ограничения openhands-broker (без права записи в реестр и secrets) ---
chmod 755 "${BROKER_LIB}"
chmod 755 "${BROKER_ETC}"
chmod 755 "${BROKER_ETC}/secrets"
# Пользователь не может менять файлы
chown -R root:root "${BROKER_LIB}" "${BROKER_ETC}"
ok "Broker user cannot modify registry, wrapper, or secrets"

# Только конкретный broker endpoint; root-controlled каталог не позволяет
# container UID или обычным host-пользователям заменить pin через rename.
KNOWN_HOSTS_TMP="$(mktemp "${BROKER_ETC}/.client-known-hosts.XXXXXX")"
printf '%s %s\n' "${BROKER_HOST}" "${LOCAL_HOST_KEY}" > "${KNOWN_HOSTS_TMP}"
chown root:10001 "${KNOWN_HOSTS_TMP}"
chmod 0640 "${KNOWN_HOSTS_TMP}"
mv -f "${KNOWN_HOSTS_TMP}" "${CLIENT_KNOWN_HOSTS}"
KNOWN_HOSTS_TMP=""
[ "$(stat -c '%u:%g:%a' "${CLIENT_KNOWN_HOSTS}")" = "0:10001:640" ] \
    || fail "Pinned known_hosts permissions are not root:10001 0640"
[ "$(stat -c '%u:%g:%a' "${BROKER_ETC}")" = "0:0:755" ] \
    || fail "Pinned known_hosts parent is not root-controlled"
[ "$(grep -cEv '^[[:space:]]*$' "${CLIENT_KNOWN_HOSTS}")" -eq 1 ] \
    || fail "Pinned known_hosts must contain exactly one entry"
ok "Persistent pinned known_hosts installed in root-controlled directory"

# setup запускается из временного checkout: сначала полностью готовим согласованные
# runtime candidates, затем атомарно заменяем только заранее разрешённые targets.
COMPOSE_TMP="$(mktemp /srv/openhands-agent/deployment/.compose.yaml.XXXXXX)"
cp "${COMPOSE_SOURCE}" "${COMPOSE_TMP}"
chown --reference="${COMPOSE_TARGET}" "${COMPOSE_TMP}"
chmod --reference="${COMPOSE_TARGET}" "${COMPOSE_TMP}"
docker compose -f "${COMPOSE_TMP}" config >/dev/null 2>&1 \
    || fail "Compose candidate with pinned known_hosts mount is invalid"

PREPARE_TMP="$(mktemp /srv/openhands-agent/deployment/scripts/.prepare.sh.XXXXXX)"
cp "${PREPARE_SOURCE}" "${PREPARE_TMP}"
chown --reference="${PREPARE_TARGET}" "${PREPARE_TMP}"
chmod 0755 "${PREPARE_TMP}"

VALIDATE_RUNTIME_TMP="$(mktemp /srv/openhands-agent/deployment/scripts/.validate-runtime.sh.XXXXXX)"
cp "${VALIDATE_RUNTIME_SOURCE}" "${VALIDATE_RUNTIME_TMP}"
chown --reference="${VALIDATE_RUNTIME_TARGET}" "${VALIDATE_RUNTIME_TMP}"
chmod 0755 "${VALIDATE_RUNTIME_TMP}"

# Новые deployment dependencies не затрагивают пользовательскую config в
# /srv/openhands-agent/config. Отсутствующие target directories создаются
# root-controlled; существующие файлы принимаются только при exact hash match.
install -d -o root -g root -m 0755 \
    /srv/openhands-agent/deployment/config \
    /srv/openhands-agent/deployment/config/profiles \
    /srv/openhands-agent/deployment/config/agent-profiles

SEED_CONFIG_TMP="$(mktemp /srv/openhands-agent/deployment/scripts/.seed-config.sh.XXXXXX)"
cp "${SEED_CONFIG_SOURCE}" "${SEED_CONFIG_TMP}"
chown root:root "${SEED_CONFIG_TMP}"
chmod 0755 "${SEED_CONFIG_TMP}"

SETTINGS_TEMPLATE_TMP="$(mktemp /srv/openhands-agent/deployment/config/.settings.json.XXXXXX)"
cp "${SETTINGS_TEMPLATE_SOURCE}" "${SETTINGS_TEMPLATE_TMP}"
chown root:root "${SETTINGS_TEMPLATE_TMP}"
chmod 0644 "${SETTINGS_TEMPLATE_TMP}"

DEEPSEEK_TEMPLATE_TMP="$(mktemp /srv/openhands-agent/deployment/config/profiles/.deepseek-chat.json.XXXXXX)"
cp "${DEEPSEEK_TEMPLATE_SOURCE}" "${DEEPSEEK_TEMPLATE_TMP}"
chown root:root "${DEEPSEEK_TEMPLATE_TMP}"
chmod 0644 "${DEEPSEEK_TEMPLATE_TMP}"

DEFAULT_AGENT_TEMPLATE_TMP="$(mktemp /srv/openhands-agent/deployment/config/agent-profiles/.default.json.XXXXXX)"
cp "${DEFAULT_AGENT_TEMPLATE_SOURCE}" "${DEFAULT_AGENT_TEMPLATE_TMP}"
chown root:root "${DEFAULT_AGENT_TEMPLATE_TMP}"
chmod 0644 "${DEFAULT_AGENT_TEMPLATE_TMP}"

# Повторная проверка непосредственно перед rename закрывает случай обычного
# расхождения target между preflight и установкой.
require_authorized_runtime_target \
    "${COMPOSE_SOURCE}" "${COMPOSE_TARGET}" "compose.yaml" \
    "${AUTHORIZED_PREVIOUS_COMPOSE_HASH}"
require_authorized_runtime_target \
    "${PREPARE_SOURCE}" "${PREPARE_TARGET}" "prepare.sh" \
    "${AUTHORIZED_PREVIOUS_PREPARE_HASHES[@]}"
require_authorized_runtime_target \
    "${VALIDATE_RUNTIME_SOURCE}" "${VALIDATE_RUNTIME_TARGET}" "validate-runtime.sh" \
    "${AUTHORIZED_PREVIOUS_VALIDATE_RUNTIME_HASHES[@]}"
require_absent_or_current_runtime_target \
    "${SEED_CONFIG_SOURCE}" "${SEED_CONFIG_TARGET}" "seed-config.sh"
require_absent_or_current_runtime_target \
    "${SETTINGS_TEMPLATE_SOURCE}" "${SETTINGS_TEMPLATE_TARGET}" "settings template"
require_absent_or_current_runtime_target \
    "${DEEPSEEK_TEMPLATE_SOURCE}" "${DEEPSEEK_TEMPLATE_TARGET}" "DeepSeek template"
require_absent_or_current_runtime_target \
    "${DEFAULT_AGENT_TEMPLATE_SOURCE}" "${DEFAULT_AGENT_TEMPLATE_TARGET}" "default agent template"

# Dependencies are renamed first: a newly installed prepare.sh can never point
# at a missing seed script or template after a successful setup.
mv -f "${SETTINGS_TEMPLATE_TMP}" "${SETTINGS_TEMPLATE_TARGET}"
SETTINGS_TEMPLATE_TMP=""
mv -f "${DEEPSEEK_TEMPLATE_TMP}" "${DEEPSEEK_TEMPLATE_TARGET}"
DEEPSEEK_TEMPLATE_TMP=""
mv -f "${DEFAULT_AGENT_TEMPLATE_TMP}" "${DEFAULT_AGENT_TEMPLATE_TARGET}"
DEFAULT_AGENT_TEMPLATE_TMP=""
mv -f "${SEED_CONFIG_TMP}" "${SEED_CONFIG_TARGET}"
SEED_CONFIG_TMP=""
mv -f "${PREPARE_TMP}" "${PREPARE_TARGET}"
PREPARE_TMP=""
mv -f "${VALIDATE_RUNTIME_TMP}" "${VALIDATE_RUNTIME_TARGET}"
VALIDATE_RUNTIME_TMP=""
mv -f "${COMPOSE_TMP}" "${COMPOSE_TARGET}"
COMPOSE_TMP=""
ok "Complete prepare dependency chain and lifecycle files installed from verified commit"

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
