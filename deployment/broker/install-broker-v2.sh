#!/usr/bin/bash
# OpenHands Broker v2 — exact v1-to-v2 migration for stage 4D.2.
# This script never installs or modifies base Canvas lifecycle files.
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly BROKER_USER="openhands-broker"
readonly BROKER_HOME="/home/openhands-broker"
readonly BROKER_LIB="/usr/local/lib/openhands-broker"
readonly BROKER_ETC="/etc/openhands-broker"
readonly BROKER_STATE="/var/lib/openhands-broker"
readonly SUDOERS_FILE="/etc/sudoers.d/openhands-broker"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/99-openhands-broker.conf"
readonly AUTH_KEYS="${BROKER_HOME}/.ssh/authorized_keys"
readonly LEGACY_CLIENT_KEY="/srv/openhands-agent/secrets/broker-mini-server.key"
readonly LEGACY_CLIENT_PUBLIC_KEY="/srv/openhands-agent/secrets/broker-mini-server.key.pub"
readonly V2_CLIENT_DIR="/srv/openhands-agent/secrets/openhands-broker-v2"
readonly V2_CLIENT_KEY="${V2_CLIENT_DIR}/id_ed25519"
readonly V2_CLIENT_PUBLIC_KEY="${V2_CLIENT_DIR}/id_ed25519.pub"
readonly HOST_PUBLIC_KEY="/etc/ssh/ssh_host_ed25519_key.pub"
readonly BROKER_ENDPOINT="10.89.0.1"
readonly CANVAS_SOURCE="10.89.0.2"
readonly LOCK_DIR="/run/lock/openhands-broker-v2"
readonly OLD_WRAPPER_BLOB="decb5e6c2c5bcc6eeb32b345da4b434ab3e1f039"
readonly OLD_JOURNAL_BLOB="9c6e79f7ce8246dba108ef11661b17d69aef2780"
readonly OLD_TOOLS_BLOB="f693aad33f34aeebd838122f654a734d4ac7043d"
readonly OLD_SUDOERS_SHA256="5d95888af66bc03dceee7990ff5c022adb3941998914b518d894583865304908b"
readonly OLD_SSHD_SHA256="60f848563df1f7585a8dad2b3fb360bd13214706e4fd4046d48376304d319e8b"
readonly -a ADAPTERS=(mini-server vps n8n github nextcloud notion amnesia)
readonly -a BASE_CANVAS_FILES=(
    /srv/openhands-agent/deployment/compose.yaml
    /srv/openhands-agent/deployment/systemd/openhands-agent.service
    /srv/openhands-agent/deployment/scripts/prepare.sh
    /srv/openhands-agent/deployment/scripts/validate-runtime.sh
    /srv/openhands-agent/deployment/scripts/seed-config.sh
    /srv/openhands-agent/deployment/scripts/run-supervised.sh
    /srv/openhands-agent/deployment/scripts/health-watchdog.sh
    /srv/openhands-agent/deployment/network/apply-egress-rules.sh
    /srv/openhands-agent/deployment/network/remove-egress-rules.sh
    /srv/openhands-agent/deployment/network/check-egress.sh
)

COMMIT_SHA="${1:-}"
PREFLIGHT_ONLY=false
if [ "${2:-}" = "--preflight-only" ]; then
    PREFLIGHT_ONLY=true
elif [ -n "${2:-}" ]; then
    printf '[FAIL] Usage: sudo %s <full-commit-sha> [--preflight-only]\n' "$0" >&2
    exit 2
fi

SNAPSHOT=""
STAGE=""
MUTATION_STARTED=false
CREATED_ADAPTER_USERS=()
TEMP_PATHS=()

ok() { printf '  [OK] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }

cleanup_temporary() {
    local path
    for path in "${TEMP_PATHS[@]:-}"; do
        [ -n "${path}" ] && rm -rf -- "${path}"
    done
    [ -n "${STAGE}" ] && rm -rf -- "${STAGE}"
}
trap cleanup_temporary EXIT

require_regular() {
    local path="$1" owner_group="$2" mode="$3"
    [ -f "${path}" ] && [ ! -L "${path}" ] || fail "Not a regular file: ${path}"
    [ "$(stat -c '%U:%G' "${path}")" = "${owner_group}" ] || fail "Unexpected owner: ${path}"
    [ "$(stat -c '%a' "${path}")" = "${mode}" ] || fail "Unexpected mode: ${path}"
}

require_directory() {
    local path="$1" owner_group="$2" mode="$3"
    [ -d "${path}" ] && [ ! -L "${path}" ] || fail "Not a directory: ${path}"
    [ "$(stat -c '%U:%G' "${path}")" = "${owner_group}" ] || fail "Unexpected owner: ${path}"
    [ "$(stat -c '%a' "${path}")" = "${mode}" ] || fail "Unexpected mode: ${path}"
}

sha256_of() {
    sha256sum -- "$1" | awk '{print $1}'
}

write_new_sshd_candidate() {
    cat > "$1" <<'EOF'
Match User openhands-broker
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForceCommand /usr/local/lib/openhands-broker/bin/broker-launcher
    DisableForwarding yes
    PermitTTY no
    PermitUserRC no
EOF
}

assert_exact_inventory() {
    local actual expected
    actual="$(find "${BROKER_LIB}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
    expected=$'broker-wrapper.sh\njournal-logs'
    [ "${actual}" = "${expected}" ] || fail "Unexpected legacy lib inventory"
    actual="$(find "${BROKER_ETC}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
    expected=$'client_known_hosts\nsecrets\ntools.yaml'
    [ "${actual}" = "${expected}" ] || fail "Unexpected legacy etc inventory"
    [ -z "$(find "${BROKER_ETC}/secrets" -mindepth 1 -maxdepth 1 -print -quit)" ] \
        || fail "Legacy secrets directory is not empty"
    actual="$(find "${BROKER_HOME}/.ssh" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
    [ "${actual}" = "authorized_keys" ] || fail "Unexpected legacy SSH inventory"
}

preflight_legacy() {
    local stored_public host_public expected_auth expected_known
    id "${BROKER_USER}" >/dev/null 2>&1 || fail "Legacy broker user is absent"
    [ "$(id -nG "${BROKER_USER}")" = "${BROKER_USER}" ] \
        || fail "Legacy broker account has unexpected supplementary groups"
    [ "$(getent passwd "${BROKER_USER}" | cut -d: -f6-7)" = "${BROKER_HOME}:/bin/bash" ] \
        || fail "Legacy broker account differs from expected baseline"
    require_directory "${BROKER_LIB}" "root:root" "755"
    require_directory "${BROKER_ETC}" "root:root" "755"
    require_directory "${BROKER_ETC}/secrets" "root:root" "755"
    require_directory "${BROKER_HOME}" "root:root" "711"
    require_directory "${BROKER_HOME}/.ssh" "root:root" "711"
    assert_exact_inventory

    require_regular "${BROKER_LIB}/broker-wrapper.sh" "root:root" "755"
    require_regular "${BROKER_LIB}/journal-logs" "root:root" "755"
    require_regular "${BROKER_ETC}/tools.yaml" "root:root" "644"
    [ "$(stat -c '%u:%g:%a' "${BROKER_ETC}/client_known_hosts")" = "0:10001:640" ] \
        || fail "Legacy pinned host trust metadata mismatch"

    [ "$(git hash-object "${BROKER_LIB}/broker-wrapper.sh")" = "${OLD_WRAPPER_BLOB}" ] \
        || fail "Legacy wrapper hash mismatch"
    [ "$(git hash-object "${BROKER_LIB}/journal-logs")" = "${OLD_JOURNAL_BLOB}" ] \
        || fail "Legacy journal helper hash mismatch"
    [ "$(git hash-object "${BROKER_ETC}/tools.yaml")" = "${OLD_TOOLS_BLOB}" ] \
        || fail "Legacy registry hash mismatch"

    require_regular "${SUDOERS_FILE}" "root:root" "440"
    require_regular "${SSHD_DROPIN}" "root:root" "600"
    require_regular "${AUTH_KEYS}" "root:${BROKER_USER}" "440"
    [ "$(sha256_of "${SUDOERS_FILE}")" = "${OLD_SUDOERS_SHA256}" ] \
        || fail "Legacy sudoers differs from frozen baseline"
    [ "$(sha256_of "${SSHD_DROPIN}")" = "${OLD_SSHD_SHA256}" ] \
        || fail "Legacy sshd drop-in differs from frozen baseline"

    [ -f "${LEGACY_CLIENT_KEY}" ] && [ ! -L "${LEGACY_CLIENT_KEY}" ] \
        || fail "Preserved legacy broker private key missing"
    [ "$(stat -c '%u:%g:%a' "${LEGACY_CLIENT_KEY}")" = "0:10001:640" ] \
        || fail "Preserved legacy broker private key metadata mismatch"
    [ -f "${LEGACY_CLIENT_PUBLIC_KEY}" ] && [ ! -L "${LEGACY_CLIENT_PUBLIC_KEY}" ] \
        || fail "Preserved legacy broker public key missing"
    [ "$(stat -c '%u:%g:%a' "${LEGACY_CLIENT_PUBLIC_KEY}")" = "1000:1000:600" ] \
        || fail "Preserved legacy broker public key metadata mismatch"
    stored_public="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${LEGACY_CLIENT_PUBLIC_KEY}")"
    [ "${stored_public%% *}" = "ssh-ed25519" ] || fail "Legacy broker public key is not ED25519"
    host_public="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${HOST_PUBLIC_KEY}")"
    [ "${host_public%% *}" = "ssh-ed25519" ] || fail "Host key is not ED25519"
    expected_auth="from=\"${CANVAS_SOURCE}\",restrict,command=\"${BROKER_LIB}/broker-wrapper.sh\" ${stored_public}"
    [ "$(cat "${AUTH_KEYS}")" = "${expected_auth}" ] || fail "Legacy authorized_keys differs from expected key/policy"
    expected_known="${BROKER_ENDPOINT} ${host_public}"
    [ "$(cat "${BROKER_ETC}/client_known_hosts")" = "${expected_known}" ] \
        || fail "Pinned host trust differs from actual ED25519 host key"
    for adapter in "${ADAPTERS[@]}"; do
        id "openhands-adapter-${adapter}" >/dev/null 2>&1 \
            && fail "Unexpected pre-existing adapter identity: openhands-adapter-${adapter}"
    done
    ok "Exact frozen v1 broker baseline verified"
}

preflight_v2_key_target() {
    local derived_public stored_public
    if [ ! -e "${V2_CLIENT_DIR}" ]; then
        return
    fi
    require_directory "${V2_CLIENT_DIR}" "root:root" "700"
    [ "$(find "${V2_CLIENT_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" \
        = $'id_ed25519\nid_ed25519.pub' ] || fail "Unexpected broker v2 key inventory"
    [ -f "${V2_CLIENT_KEY}" ] && [ ! -L "${V2_CLIENT_KEY}" ] \
        || fail "Broker v2 private key is missing or symlinked"
    [ "$(stat -c '%u:%g:%a' "${V2_CLIENT_KEY}")" = "10001:10001:600" ] \
        || fail "Broker v2 private key metadata mismatch"
    require_regular "${V2_CLIENT_PUBLIC_KEY}" "root:root" "644"
    derived_public="$(ssh-keygen -y -f "${V2_CLIENT_KEY}")" || fail "Cannot derive broker v2 public key"
    stored_public="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${V2_CLIENT_PUBLIC_KEY}")"
    [ "${derived_public}" = "${stored_public}" ] || fail "Broker v2 private/public key mismatch"
}

verify_source_commit() {
    local source_path
    [[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "A full commit SHA is required"
    SCRIPT_DIR="$(CDPATH= cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
    REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
    cd "${REPO_ROOT}"
    [ "$(git rev-parse HEAD)" = "${COMMIT_SHA}" ] || fail "Source HEAD does not match approved commit"
    git diff --quiet HEAD -- || fail "Tracked source files are modified"
    git diff --cached --quiet HEAD -- || fail "Source index is modified"
    [ -z "$(git ls-files --others --exclude-standard)" ] || fail "Source contains untracked files"
    for source_path in \
        deployment/broker/install-broker-v2.sh \
        deployment/broker/rollback-broker-v1.sh \
        deployment/broker/uninstall-broker-v2.sh \
        deployment/broker/validate-install-v2.sh \
        deployment/broker/bin/broker-launcher \
        deployment/broker/broker_core.py \
        deployment/broker/adapters/core-adapter \
        deployment/broker/tools.d/core.yaml; do
        git ls-files --error-unmatch "${source_path}" >/dev/null 2>&1 || fail "Untracked source: ${source_path}"
        [ "$(git hash-object "${source_path}")" = "$(git rev-parse "${COMMIT_SHA}:${source_path}")" ] \
            || fail "Source differs from approved commit: ${source_path}"
    done
}

write_base_canvas_manifest() {
    local path
    : > "${SNAPSHOT}/BASE-CANVAS.sha256"
    for path in "${BASE_CANVAS_FILES[@]}"; do
        [ -f "${path}" ] && [ ! -L "${path}" ] || fail "Base Canvas invariant missing: ${path}"
        printf '%s  %s\n' "$(sha256_of "${path}")" "${path}" >> "${SNAPSHOT}/BASE-CANVAS.sha256"
    done
    chmod 0600 "${SNAPSHOT}/BASE-CANVAS.sha256"
}

verify_base_canvas_manifest() {
    [ -f "${SNAPSHOT}/BASE-CANVAS.sha256" ] || fail "Base Canvas invariant manifest missing"
    sha256sum -c --status "${SNAPSHOT}/BASE-CANVAS.sha256" \
        || fail "Base Canvas files changed during broker migration"
}

ensure_v2_keypair() {
    local key_stage derived_public stored_public
    if [ -e "${V2_CLIENT_DIR}" ]; then
        preflight_v2_key_target
        ok "Existing exact broker v2 client keypair preserved and reused"
        return
    fi

    key_stage="$(mktemp -d /run/openhands-broker-v2-key.XXXXXX)"
    TEMP_PATHS+=("${key_stage}")
    ssh-keygen -q -t ed25519 -N '' -C openhands-broker-v2 -f "${key_stage}/id_ed25519"
    derived_public="$(ssh-keygen -y -f "${key_stage}/id_ed25519")"
    stored_public="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${key_stage}/id_ed25519.pub")"
    [ "${derived_public}" = "${stored_public}" ] || fail "Generated broker v2 keypair mismatch"

    mkdir -m 0700 -- "${V2_CLIENT_DIR}"
    chown root:root "${V2_CLIENT_DIR}"
    install -o 10001 -g 10001 -m 0600 "${key_stage}/id_ed25519" "${V2_CLIENT_KEY}"
    install -o root -g root -m 0644 "${key_stage}/id_ed25519.pub" "${V2_CLIENT_PUBLIC_KEY}"
    sync -f "${V2_CLIENT_DIR}"
    preflight_v2_key_target
    ok "Separate broker v2 client keypair created without changing legacy keys"
}

assert_no_broker_sudo_grants() {
    local policy
    policy="$(sudo -l -U "${BROKER_USER}" 2>&1 || true)"
    if grep -Eq 'NOPASSWD|/usr/|/bin/|ALL[[:space:]]*=' <<<"${policy}"; then
        fail "Broker retains a sudo command grant"
    fi
}

create_snapshot() {
    local stamp
    install -d -o root -g root -m 0711 "${BROKER_STATE}"
    install -d -o root -g root -m 0700 "${BROKER_STATE}/migrations"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    SNAPSHOT="${BROKER_STATE}/migrations/${stamp}-v1-to-${COMMIT_SHA:0:12}"
    mkdir -m 0700 "${SNAPSHOT}"
    printf 'openhands-broker-v1-snapshot\n' > "${SNAPSHOT}/FORMAT"
    cp -a "${BROKER_LIB}" "${SNAPSHOT}/lib"
    cp -a "${BROKER_ETC}" "${SNAPSHOT}/etc"
    cp -a "${BROKER_HOME}" "${SNAPSHOT}/home"
    cp -a "${SUDOERS_FILE}" "${SNAPSHOT}/sudoers"
    cp -a "${SSHD_DROPIN}" "${SNAPSHOT}/sshd-dropin"
    getent passwd "${BROKER_USER}" > "${SNAPSHOT}/passwd"
    getent group "${BROKER_USER}" > "${SNAPSHOT}/group"
    write_base_canvas_manifest
    ok "Root-only broker rollback snapshot created: ${SNAPSHOT}"
}

restore_snapshot() {
    local user
    set +e
    printf '  [ROLLBACK] Restoring exact frozen broker artifacts\n' >&2
    rm -rf -- "${BROKER_LIB}" "${BROKER_ETC}" "${BROKER_HOME}"
    cp -a "${SNAPSHOT}/lib" "${BROKER_LIB}"
    cp -a "${SNAPSHOT}/etc" "${BROKER_ETC}"
    cp -a "${SNAPSHOT}/home" "${BROKER_HOME}"
    cp -a "${SNAPSHOT}/sudoers" "${SUDOERS_FILE}"
    cp -a "${SNAPSHOT}/sshd-dropin" "${SSHD_DROPIN}"
    rm -f -- "${BROKER_STATE}/install-state.json"
    rm -rf -- "${BROKER_STATE}/adapters"
    rm -rf -- /run/openhands-broker
    for user in "${CREATED_ADAPTER_USERS[@]:-}"; do
        [ -n "${user}" ] && userdel "${user}" >/dev/null 2>&1
    done
    if ! sshd -t || ! systemctl reload ssh.service; then
        printf '  [CRITICAL] Frozen sshd policy was restored on disk but reload failed\n' >&2
        set -e
        return 1
    fi
    if ! sha256sum -c --status "${SNAPSHOT}/BASE-CANVAS.sha256"; then
        printf '  [CRITICAL] Base Canvas invariant changed; broker rollback cannot repair it\n' >&2
        set -e
        return 1
    fi
    set -e
    return 0
}

on_error() {
    local rc=$?
    trap - ERR
    if [ "${MUTATION_STARTED}" = true ] && [ -n "${SNAPSHOT}" ]; then
        if ! restore_snapshot; then
            printf '  [CRITICAL] Automatic broker rollback requires operator inspection\n' >&2
        fi
    fi
    printf '  [FAIL] Migration aborted (exit %s); no base Canvas files were touched\n' "${rc}" >&2
    exit "${rc}"
}

install_v2() {
    local adapter user derived_public host_public
    STAGE="$(mktemp -d /run/openhands-broker-v2-stage.XXXXXX)"
    TEMP_PATHS+=("${STAGE}")
    install -d -m 0755 "${STAGE}/lib/bin" "${STAGE}/lib/adapters"
    install -o root -g root -m 0755 deployment/broker/broker_core.py "${STAGE}/lib/broker_core.py"
    install -o root -g root -m 0755 deployment/broker/bin/broker-launcher "${STAGE}/lib/bin/broker-launcher"
    install -o root -g root -m 0755 deployment/broker/adapters/core-adapter "${STAGE}/lib/adapters/core-adapter"
    python3 -c 'import pathlib,sys; [compile(pathlib.Path(p).read_text(encoding="utf-8"), p, "exec") for p in sys.argv[1:]]' \
        "${STAGE}/lib/broker_core.py" "${STAGE}/lib/adapters/core-adapter"

    create_snapshot
    MUTATION_STARTED=true
    trap on_error ERR
    ensure_v2_keypair

    rm -rf -- "${BROKER_LIB}"
    mv "${STAGE}/lib" "${BROKER_LIB}"
    chown -R root:root "${BROKER_LIB}"
    chmod 0755 "${BROKER_LIB}" "${BROKER_LIB}/bin" "${BROKER_LIB}/adapters"

    rm -f -- "${BROKER_ETC}/tools.yaml"
    rmdir -- "${BROKER_ETC}/secrets"
    install -d -o root -g root -m 0755 "${BROKER_ETC}" "${BROKER_ETC}/tools.d" \
        "${BROKER_ETC}/adapters" "${BROKER_ETC}/secrets.d"
    install -o root -g root -m 0644 deployment/broker/tools.d/core.yaml "${BROKER_ETC}/tools.d/core.yaml"
    ln -s "${BROKER_ETC}/tools.d" "${BROKER_LIB}/tools.d"

    install -d -o root -g root -m 0711 "${BROKER_STATE}" "${BROKER_STATE}/adapters"

    for adapter in "${ADAPTERS[@]}"; do
        user="openhands-adapter-${adapter}"
        if ! id "${user}" >/dev/null 2>&1; then
            useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
                --comment "OpenHands isolated ${adapter} adapter" "${user}"
            CREATED_ADAPTER_USERS+=("${user}")
        fi
        install -d -o root -g "${user}" -m 0750 "${BROKER_ETC}/adapters/${adapter}"
        install -d -o root -g "${user}" -m 0750 "${BROKER_ETC}/secrets.d/${adapter}"
        install -d -o "${user}" -g "${user}" -m 0700 "${BROKER_STATE}/adapters/${adapter}"
    done

    install -d -o root -g root -m 0700 /run/openhands-broker \
        /run/openhands-broker/approvals /run/openhands-broker/inflight /run/openhands-broker/consumed

    derived_public="$(ssh-keygen -y -f "${V2_CLIENT_KEY}")"
    install -d -o root -g root -m 0711 "${BROKER_HOME}" "${BROKER_HOME}/.ssh"
    printf 'from="%s",restrict,command="%s/bin/broker-launcher" %s\n' \
        "${CANVAS_SOURCE}" "${BROKER_LIB}" "${derived_public}" > "${AUTH_KEYS}.new"
    chown root:"${BROKER_USER}" "${AUTH_KEYS}.new"
    chmod 0440 "${AUTH_KEYS}.new"
    mv -f "${AUTH_KEYS}.new" "${AUTH_KEYS}"

    host_public="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${HOST_PUBLIC_KEY}")"
    printf '%s %s\n' "${BROKER_ENDPOINT}" "${host_public}" > "${BROKER_ETC}/client_known_hosts.new"
    chown root:10001 "${BROKER_ETC}/client_known_hosts.new"
    chmod 0640 "${BROKER_ETC}/client_known_hosts.new"
    mv -f "${BROKER_ETC}/client_known_hosts.new" "${BROKER_ETC}/client_known_hosts"

    rm -f -- "${SUDOERS_FILE}"
    visudo -c >/dev/null
    assert_no_broker_sudo_grants

    write_new_sshd_candidate "${STAGE}/sshd-dropin"
    sshd -t -f "${STAGE}/sshd-dropin"
    install -o root -g root -m 0600 "${STAGE}/sshd-dropin" "${SSHD_DROPIN}.new"
    mv -f "${SSHD_DROPIN}.new" "${SSHD_DROPIN}"
    sshd -t
    systemctl reload ssh.service

    printf '{"version":1,"commit":"%s","legacy_snapshot":"%s","level_b_enabled":false,"level_c_enabled":false}\n' \
        "${COMMIT_SHA}" "${SNAPSHOT}" > "${BROKER_STATE}/install-state.json.new"
    chown root:root "${BROKER_STATE}/install-state.json.new"
    chmod 0600 "${BROKER_STATE}/install-state.json.new"
    mv -f "${BROKER_STATE}/install-state.json.new" "${BROKER_STATE}/install-state.json"

    deployment/broker/validate-install-v2.sh "${COMMIT_SHA}"
    verify_base_canvas_manifest
    logger --tag openhands-broker-setup -- \
        "{\"event\":\"MIGRATION_SUCCEEDED\",\"commit\":\"${COMMIT_SHA}\"}"
    trap - ERR
    MUTATION_STARTED=false
    rm -rf -- "${STAGE}"
    STAGE=""
    ok "Broker v2 migration completed"
}

[ "$(id -u)" -eq 0 ] || fail "Run with sudo"
for command_name in git python3 logger sshd visudo sudo useradd userdel install flock ssh-keygen runuser sha256sum sync; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "Missing dependency: ${command_name}"
done
verify_source_commit
preflight_legacy
preflight_v2_key_target
sshd -t || fail "Current sshd configuration is invalid"

if [ "${PREFLIGHT_ONLY}" = true ]; then
    ok "Read-only preflight completed; no filesystem or audit mutation performed"
    exit 0
fi

install -d -o root -g root -m 0755 "${LOCK_DIR}"
exec 9>"${LOCK_DIR}/migration.lock"
flock -n 9 || fail "Another broker migration is running"
logger --tag openhands-broker-setup -- '{"event":"MIGRATION_PREFLIGHT_OK"}' \
    || fail "Audit transport is unavailable"
install_v2
