#!/usr/bin/bash
# Stage 4D.4 — transactional Canvas Connector install with automatic rollback.
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly BASE_COMMIT="f636ed90dd4c54ad83073a821f7f0111fa26f07a"
readonly BASE="/srv/openhands-agent"
readonly BROKER_STATE="/var/lib/openhands-broker"
readonly BROKER_INSTALL_STATE="${BROKER_STATE}/install-state.json"
readonly CONNECTOR_STATE="${BROKER_STATE}/connector-state.json"
readonly IMAGE="openhands-agent-canvas-broker:1.6.1-4d4"
readonly KEY="${BASE}/secrets/openhands-broker-v2/id_ed25519"
readonly TRUST="/etc/openhands-broker/client_known_hosts"
readonly -a CHANGED_FILES=(
    deployment/compose.yaml
    deployment/network/apply-egress-rules.sh
    deployment/network/check-egress.sh
    deployment/network/README.md
    deployment/scripts/validate-runtime.sh
    deployment/scripts/validate-static.sh
)
readonly -a PRECONNECTOR_FILES=(
    deployment/compose.yaml
    deployment/systemd/openhands-agent.service
    deployment/scripts/prepare.sh
    deployment/scripts/validate-runtime.sh
    deployment/scripts/seed-config.sh
    deployment/scripts/run-supervised.sh
    deployment/scripts/health-watchdog.sh
    deployment/network/apply-egress-rules.sh
    deployment/network/remove-egress-rules.sh
    deployment/network/check-egress.sh
    deployment/network/README.md
    deployment/scripts/validate-static.sh
)
readonly -a CANONICAL_FILES=(
    "${PRECONNECTOR_FILES[@]}"
    deployment/connector/README.md
    deployment/connector/Dockerfile
    deployment/connector/broker-client.py
    deployment/connector/install-canvas-connector.sh
    deployment/connector/validate-canvas-connector.sh
    deployment/connector/rollback-canvas-connector.sh
    deployment/connector/accept-level-a-e2e.sh
)

COMMIT_SHA="${1:-}"
PREFLIGHT_ONLY=false
SNAPSHOT=""
STAGE=""
MUTATION_STARTED=false

ok() { printf '  [OK] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }

cleanup() {
    [ -z "${STAGE}" ] || rm -rf -- "${STAGE}"
}
trap cleanup EXIT

if [ "${2:-}" = "--preflight-only" ]; then
    PREFLIGHT_ONLY=true
elif [ "$#" -ne 1 ]; then
    fail "Usage: $0 <full-commit-sha> [--preflight-only]"
fi

state_value() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], ""))' "$1" "$2"
}

verify_source() {
    [ "$(id -u)" -eq 0 ] || fail "Run with sudo"
    [[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "A full commit SHA is required"
    [ "$(git rev-parse HEAD)" = "${COMMIT_SHA}" ] || fail "Checkout HEAD differs from approved commit"
    [ -z "$(git status --porcelain)" ] || fail "Checkout is not clean"
    git merge-base --is-ancestor "${BASE_COMMIT}" "${COMMIT_SHA}" || fail "Completed 4D.3 commit is not an ancestor"
}

compare_preconnector_file() {
    local path="$1"
    git show "${BASE_COMMIT}:${path}" | cmp -s - "${BASE}/${path}" \
        || fail "Installed pre-connector file differs from completed 4D.3 baseline: ${path}"
}

verify_broker_stage() {
    [ -f "${BROKER_INSTALL_STATE}" ] && [ ! -L "${BROKER_INSTALL_STATE}" ] || fail "Broker install state missing or symlinked"
    [ "$(state_value "${BROKER_INSTALL_STATE}" stage)" = "4D.3" ] || fail "4D.3 is not installed"
    [ "$(state_value "${BROKER_INSTALL_STATE}" commit)" = "${BASE_COMMIT}" ] || fail "Installed 4D.3 commit mismatch"
    legacy_snapshot="$(state_value "${BROKER_INSTALL_STATE}" legacy_snapshot)"
    case "$(realpath -e -- "${legacy_snapshot}")" in
        "${BROKER_STATE}/migrations/"*) ;;
        *) fail "Broker state references an untrusted 4D.2 snapshot" ;;
    esac
    sha256sum -c --status "${legacy_snapshot}/BASE-CANVAS.sha256" || fail "Pre-connector base Canvas manifest mismatch"
}

verify_connector_file() {
    local path="$1"
    [ -f "${path}" ] && [ ! -L "${path}" ] || fail "Connector credential/trust file missing or symlinked"
    [ "$(stat -c '%u:%g:%a' "${path}")" = "0:10001:640" ] || fail "Connector credential/trust metadata mismatch"
}

verify_image_state() {
    if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        [ "$(docker image inspect --format '{{ index .Config.Labels \"org.openhands.connector.stage\" }}' "${IMAGE}")" = "4D.4" ] \
            || fail "Existing connector image has an unexpected stage label"
        [ "$(docker image inspect --format '{{ index .Config.Labels \"org.openhands.connector.source\" }}' "${IMAGE}")" = "${COMMIT_SHA}" ] \
            || fail "Existing connector image belongs to another source commit"
    fi
}

preflight() {
    [ ! -e "${CONNECTOR_STATE}" ] || fail "Connector state already exists; use validator"
    [ ! -e "${BASE}/deployment/connector" ] || fail "Unexpected pre-existing runtime connector directory"
    for path in "${CHANGED_FILES[@]}"; do compare_preconnector_file "${path}"; done
    verify_broker_stage
    verify_connector_file "${KEY}"
    verify_connector_file "${TRUST}"
    systemctl is-active --quiet openhands-agent.service || fail "Base Canvas service is not active"
    [ "$(docker inspect --format '{{.State.Health.Status}}' openhands-agent)" = "healthy" ] || fail "Base Canvas container is not healthy"
    verify_image_state
    ok "Exact completed 4D.3 + pre-connector Canvas baseline verified"
}

build_image() {
    if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        ok "Exact connector image already exists"
        return
    fi
    docker build --pull=false --build-arg "SOURCE_COMMIT=${COMMIT_SHA}" \
        --tag "${IMAGE}" --file deployment/connector/Dockerfile deployment/connector
    verify_image_state
    docker run --rm --entrypoint /bin/sh "${IMAGE}" -c \
        'test "$(id -u):$(id -g)" = "10001:10001" && ssh -V 2>&1 | grep -q "OpenSSH_10.0p1" && test -x /usr/local/bin/openhands-broker-client'
    ok "Pinned connector image built and validated"
}

write_manifest() {
    local output="$1" path
    : > "${output}"
    for path in "${CANONICAL_FILES[@]}"; do
        [ -f "${BASE}/${path}" ] && [ ! -L "${BASE}/${path}" ] || fail "Canonical Canvas file missing or symlinked: ${path}"
        sha256sum "${BASE}/${path}" >> "${output}"
    done
    chmod 0600 "${output}"
}

create_snapshot() {
    local stamp short
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    short="${COMMIT_SHA:0:12}"
    SNAPSHOT="${BROKER_STATE}/connectors/${stamp}-pre-4d4-to-${short}"
    install -d -o root -g root -m 0700 "${BROKER_STATE}/connectors" "${SNAPSHOT}"
    cp -a -- "${BASE}/deployment" "${SNAPSHOT}/deployment"
    : > "${SNAPSHOT}/PRE-CONNECTOR.sha256"
    for path in "${PRECONNECTOR_FILES[@]}"; do
        sha256sum "${BASE}/${path}" >> "${SNAPSHOT}/PRE-CONNECTOR.sha256"
    done
    chmod 0600 "${SNAPSHOT}/PRE-CONNECTOR.sha256"
    sync "${SNAPSHOT}"
    ok "Root-only pre-connector snapshot created: ${SNAPSHOT}"
}

wait_canvas_healthy() {
    for _ in $(seq 1 60); do
        if systemctl is-active --quiet openhands-agent.service \
            && [ "$(docker inspect --format '{{.State.Health.Status}}' openhands-agent 2>/dev/null || true)" = "healthy" ]; then
            curl -fsS -o /dev/null --max-time 5 http://10.77.0.2:8000/canvas && return 0
        fi
        sleep 2
    done
    return 1
}

restore_preconnector() {
    local path
    [ -n "${SNAPSHOT}" ] && [ -d "${SNAPSHOT}/deployment" ] || return 1
    systemctl stop openhands-agent.service || true
    for path in "${CHANGED_FILES[@]}"; do
        install -d -o root -g root -m 0755 "$(dirname "${BASE}/${path}")"
        cp -a -- "${SNAPSHOT}/${path}" "${BASE}/${path}"
    done
    rm -rf -- "${BASE}/deployment/connector"
    rm -f -- "${CONNECTOR_STATE}"
    sha256sum -c --status "${SNAPSHOT}/PRE-CONNECTOR.sha256" || return 1
    systemctl start openhands-agent.service
    wait_canvas_healthy
}

on_error() {
    local rc=$?
    trap - ERR
    if [ "${MUTATION_STARTED}" = true ]; then
        if restore_preconnector; then
            printf '  [ROLLBACK] Exact pre-connector Canvas deployment restored\n' >&2
        else
            printf '  [CRITICAL] Connector rollback requires operator inspection\n' >&2
        fi
    fi
    printf '  [FAIL] Canvas Connector install aborted (exit %s); protected data was not touched\n' "${rc}" >&2
    exit "${rc}"
}

publish_connector_files() {
    local path
    for path in "${CHANGED_FILES[@]}"; do
        mode=0644
        case "${path}" in *.sh) mode=0755 ;; esac
        install -o root -g root -m "${mode}" "${path}" "${BASE}/${path}"
    done
    install -d -o root -g root -m 0755 "${BASE}/deployment/connector"
    install -o root -g root -m 0644 deployment/connector/README.md "${BASE}/deployment/connector/README.md"
    install -o root -g root -m 0644 deployment/connector/Dockerfile "${BASE}/deployment/connector/Dockerfile"
    install -o root -g root -m 0755 deployment/connector/broker-client.py "${BASE}/deployment/connector/broker-client.py"
    for script in install-canvas-connector.sh validate-canvas-connector.sh rollback-canvas-connector.sh accept-level-a-e2e.sh; do
        install -o root -g root -m 0755 "deployment/connector/${script}" "${BASE}/deployment/connector/${script}"
    done
}

install_connector() {
    local image_id broker_commit
    build_image
    image_id="$(docker image inspect --format '{{.Id}}' "${IMAGE}")"
    broker_commit="$(state_value "${BROKER_INSTALL_STATE}" commit)"
    create_snapshot
    MUTATION_STARTED=true
    trap on_error ERR
    systemctl stop openhands-agent.service
    publish_connector_files
    write_manifest "${SNAPSHOT}/CANONICAL-CANVAS.sha256"
    python3 -c 'import json,sys; print(json.dumps({"version":1,"stage":"4D.4","commit":sys.argv[1],"broker_commit":sys.argv[2],"image":sys.argv[3],"image_id":sys.argv[4],"pre_connector_snapshot":sys.argv[5],"canonical_manifest":sys.argv[6]}, sort_keys=True, separators=(",", ":")))' \
        "${COMMIT_SHA}" "${broker_commit}" "${IMAGE}" "${image_id}" "${SNAPSHOT}" "${SNAPSHOT}/CANONICAL-CANVAS.sha256" \
        > "${STAGE}/connector-state.json"
    install -o root -g root -m 0600 "${STAGE}/connector-state.json" "${CONNECTOR_STATE}"
    systemctl start openhands-agent.service
    deployment/connector/validate-canvas-connector.sh "${COMMIT_SHA}"
    logger --tag openhands-broker-setup -- "{\"event\":\"CANVAS_CONNECTOR_INSTALLED\",\"commit\":\"${COMMIT_SHA}\"}"
    trap - ERR
    MUTATION_STARTED=false
    ok "4D.4 Canvas Connector installed and validated"
}

for command_name in git python3 docker systemctl iptables sha256sum install logger curl; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "Missing dependency: ${command_name}"
done
verify_source
preflight
if [ "${PREFLIGHT_ONLY}" = true ]; then
    ok "Read-only 4D.4 preflight completed; no filesystem, image, service, firewall, or audit mutation performed"
    exit 0
fi
STAGE="$(mktemp -d /run/openhands-connector-4d4.XXXXXX)"
install_connector
