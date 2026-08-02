#!/usr/bin/bash
# Stage 4D.3 — transactional Broker v2 Level A update. Never touches base Canvas files.
set -euo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly BASE_COMMIT="f9c97c4cc113b081f19c455bd193e014fa3d7585"
readonly BROKER_USER="openhands-broker"
readonly ADAPTER_USER="openhands-adapter-mini-server"
readonly BROKER_LIB="/usr/local/lib/openhands-broker"
readonly BROKER_ETC="/etc/openhands-broker"
readonly BROKER_STATE="/var/lib/openhands-broker"
readonly INSTALL_STATE="${BROKER_STATE}/install-state.json"
readonly SUDOERS_FILE="/etc/sudoers.d/openhands-broker-v2-mini-server"
readonly LOCK_DIR="/run/lock/openhands-broker-v2"
COMMIT_SHA="${1:-}"
PREFLIGHT_ONLY=false
SNAPSHOT=""
STAGE=""
MUTATION_STARTED=false

fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
ok() { printf '  [OK] %s\n' "$1"; }

cleanup() {
    [ -z "${STAGE}" ] || rm -rf -- "${STAGE}"
}
trap cleanup EXIT

if [ "${2:-}" = "--preflight-only" ]; then
    PREFLIGHT_ONLY=true
elif [ "$#" -ne 1 ]; then
    fail "Usage: $0 <full-commit-sha> [--preflight-only]"
fi

verify_source() {
    [ "$(id -u)" -eq 0 ] || fail "Run with sudo"
    [[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "A full commit SHA is required"
    [ "$(git rev-parse HEAD)" = "${COMMIT_SHA}" ] || fail "Checkout HEAD differs from approved commit"
    [ -z "$(git status --porcelain)" ] || fail "Checkout is not clean"
    git merge-base --is-ancestor "${BASE_COMMIT}" "${COMMIT_SHA}" \
        || fail "Approved 4D.2 commit is not an ancestor"
}

state_value() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], ""))' \
        "${INSTALL_STATE}" "$1"
}

verify_base_canvas() {
    local legacy_snapshot resolved
    legacy_snapshot="$(state_value legacy_snapshot)"
    resolved="$(realpath -e -- "${legacy_snapshot}")" || fail "Legacy snapshot is missing"
    case "${resolved}" in
        "${BROKER_STATE}/migrations/"*) ;;
        *) fail "Install state references an untrusted migration snapshot" ;;
    esac
    sha256sum -c --status "${resolved}/BASE-CANVAS.sha256" \
        || fail "Base Canvas files differ from the protected 4D.2 manifest"
}

compare_base_artifact() {
    local repository_path="$1" installed_path="$2"
    git show "${BASE_COMMIT}:${repository_path}" | cmp -s - "${installed_path}" \
        || fail "Installed 4D.2 artifact differs from approved baseline: ${installed_path}"
}

preflight() {
    [ -f "${INSTALL_STATE}" ] && [ ! -L "${INSTALL_STATE}" ] || fail "Broker install state is missing or symlinked"
    if [ "$(state_value commit)" = "${COMMIT_SHA}" ] && [ "$(state_value stage)" = "4D.3" ]; then
        fail "4D.3 is already installed; run validate-level-a-v2.sh instead"
    fi
    [ "$(state_value commit)" = "${BASE_COMMIT}" ] || fail "Installed broker is not the exact completed 4D.2 baseline"
    compare_base_artifact deployment/broker/broker_core.py "${BROKER_LIB}/broker_core.py"
    compare_base_artifact deployment/broker/bin/broker-launcher "${BROKER_LIB}/bin/broker-launcher"
    compare_base_artifact deployment/broker/adapters/core-adapter "${BROKER_LIB}/adapters/core-adapter"
    compare_base_artifact deployment/broker/tools.d/core.yaml "${BROKER_ETC}/tools.d/core.yaml"
    [ ! -e "${BROKER_LIB}/adapters/mini-server-adapter" ] || fail "Unexpected pre-existing mini-server adapter"
    [ ! -e "${BROKER_ETC}/tools.d/mini-server.yaml" ] || fail "Unexpected pre-existing mini-server registry"
    [ ! -e "${SUDOERS_FILE}" ] || fail "Unexpected pre-existing 4D.3 sudoers policy"
    id "${ADAPTER_USER}" >/dev/null 2>&1 || fail "4D.2 mini-server adapter identity is missing"
    [ "$(getent passwd "${ADAPTER_USER}" | cut -d: -f6-7)" = "/nonexistent:/usr/sbin/nologin" ] \
        || fail "Mini-server adapter identity contract mismatch"
    verify_base_canvas
    ok "Exact completed 4D.2 baseline verified for 4D.3 update"
}

create_snapshot() {
    local stamp short
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    short="${COMMIT_SHA:0:12}"
    SNAPSHOT="${BROKER_STATE}/updates/${stamp}-4d3-to-${short}"
    install -d -o root -g root -m 0700 "${BROKER_STATE}/updates" "${SNAPSHOT}"
    cp -a -- "${BROKER_LIB}/broker_core.py" "${SNAPSHOT}/broker_core.py"
    cp -a -- "${BROKER_ETC}/tools.d/core.yaml" "${SNAPSHOT}/core.yaml"
    cp -a -- "${INSTALL_STATE}" "${SNAPSHOT}/install-state.json"
    sync "${SNAPSHOT}"
    ok "Root-only 4D.3 rollback snapshot created: ${SNAPSHOT}"
}

rollback() {
    [ -n "${SNAPSHOT}" ] && [ -d "${SNAPSHOT}" ] || return 1
    install -o root -g root -m 0755 "${SNAPSHOT}/broker_core.py" "${BROKER_LIB}/broker_core.py"
    install -o root -g root -m 0644 "${SNAPSHOT}/core.yaml" "${BROKER_ETC}/tools.d/core.yaml"
    install -o root -g root -m 0600 "${SNAPSHOT}/install-state.json" "${INSTALL_STATE}"
    rm -f -- "${BROKER_LIB}/adapters/mini-server-adapter" \
        "${BROKER_ETC}/tools.d/mini-server.yaml" "${SUDOERS_FILE}"
    visudo -c >/dev/null
    verify_base_canvas
}

on_error() {
    local rc=$?
    trap - ERR
    if [ "${MUTATION_STARTED}" = true ]; then
        if rollback; then
            printf '  [ROLLBACK] Restored exact completed 4D.2 broker state\n' >&2
        else
            printf '  [CRITICAL] 4D.3 rollback requires operator inspection\n' >&2
        fi
    fi
    printf '  [FAIL] 4D.3 update aborted (exit %s); no base Canvas files were touched\n' "${rc}" >&2
    exit "${rc}"
}

install_level_a() {
    STAGE="$(mktemp -d /run/openhands-broker-v2-4d3.XXXXXX)"
    install -d -m 0755 "${STAGE}/adapters" "${STAGE}/tools.d"
    install -o root -g root -m 0755 deployment/broker/broker_core.py "${STAGE}/broker_core.py"
    install -o root -g root -m 0755 deployment/broker/adapters/mini-server-adapter "${STAGE}/adapters/mini-server-adapter"
    install -o root -g root -m 0644 deployment/broker/tools.d/mini-server.yaml "${STAGE}/tools.d/mini-server.yaml"
    python3 -m py_compile "${STAGE}/broker_core.py" "${STAGE}/adapters/mini-server-adapter"
    printf '%s\n' \
        "${BROKER_USER} ALL=(${ADAPTER_USER}) NOPASSWD: ${BROKER_LIB}/adapters/mini-server-adapter \"\"" \
        > "${STAGE}/sudoers"
    chmod 0440 "${STAGE}/sudoers"
    visudo -cf "${STAGE}/sudoers" >/dev/null

    create_snapshot
    MUTATION_STARTED=true
    trap on_error ERR
    install -o root -g root -m 0755 "${STAGE}/broker_core.py" "${BROKER_LIB}/broker_core.py"
    install -o root -g root -m 0755 "${STAGE}/adapters/mini-server-adapter" "${BROKER_LIB}/adapters/mini-server-adapter"
    install -o root -g root -m 0644 "${STAGE}/tools.d/mini-server.yaml" "${BROKER_ETC}/tools.d/mini-server.yaml"
    install -o root -g root -m 0440 "${STAGE}/sudoers" "${SUDOERS_FILE}"
    visudo -c >/dev/null
    python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p, encoding="utf-8")); s["commit"]=sys.argv[2]; s["stage"]="4D.3"; s["level_a_update_snapshot"]=sys.argv[3]; open(sys.argv[4], "w", encoding="utf-8").write(json.dumps(s, sort_keys=True, separators=(",", ":"))+"\n")' \
        "${SNAPSHOT}/install-state.json" "${COMMIT_SHA}" "${SNAPSHOT}" "${STAGE}/install-state.json"
    install -o root -g root -m 0600 "${STAGE}/install-state.json" "${INSTALL_STATE}"
    deployment/broker/validate-level-a-v2.sh "${COMMIT_SHA}"
    logger --tag openhands-broker-setup -- \
        "{\"event\":\"LEVEL_A_INSTALLED\",\"commit\":\"${COMMIT_SHA}\"}"
    trap - ERR
    MUTATION_STARTED=false
    ok "4D.3 mini-server Level A update completed"
}

for command_name in git python3 logger visudo sudo install flock sha256sum runuser systemctl; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "Missing dependency: ${command_name}"
done
verify_source
preflight
if [ "${PREFLIGHT_ONLY}" = true ]; then
    ok "Read-only 4D.3 preflight completed; no filesystem or audit mutation performed"
    exit 0
fi
install -d -o root -g root -m 0755 "${LOCK_DIR}"
exec 9>"${LOCK_DIR}/level-a.lock"
flock -n 9 || fail "Another broker update is running"
install_level_a
