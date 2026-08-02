#!/usr/bin/bash
# Read-only validation of the installed 4D.3 mini-server Level A adapter.
set -euo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly BROKER_USER="openhands-broker"
readonly ADAPTER_USER="openhands-adapter-mini-server"
readonly BROKER_LIB="/usr/local/lib/openhands-broker"
readonly BROKER_ETC="/etc/openhands-broker"
readonly BROKER_STATE="/var/lib/openhands-broker"
readonly SUDOERS_FILE="/etc/sudoers.d/openhands-broker-v2-mini-server"
COMMIT_SHA="${1:-}"

fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
ok() { printf '  [OK] %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || fail "Run with sudo"
[[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "A full commit SHA is required"
[ "$(git rev-parse HEAD)" = "${COMMIT_SHA}" ] || fail "Checkout HEAD differs from approved commit"
[ -z "$(git status --porcelain)" ] || fail "Checkout is not clean"

for pair in \
    "deployment/broker/broker_core.py:${BROKER_LIB}/broker_core.py" \
    "deployment/broker/adapters/mini-server-adapter:${BROKER_LIB}/adapters/mini-server-adapter" \
    "deployment/broker/tools.d/mini-server.yaml:${BROKER_ETC}/tools.d/mini-server.yaml"; do
    source_path="${pair%%:*}"
    installed_path="${pair#*:}"
    [ -f "${installed_path}" ] && [ ! -L "${installed_path}" ] || fail "Installed Level A artifact missing or symlinked"
    cmp -s "${source_path}" "${installed_path}" || fail "Installed Level A artifact differs from approved source"
    [ "$(stat -c '%U:%G' "${installed_path}")" = "root:root" ] || fail "Level A artifact is not root-owned"
done
[ "$(stat -c '%a' "${BROKER_LIB}/broker_core.py")" = "755" ] || fail "Broker core mode mismatch"
[ "$(stat -c '%a' "${BROKER_LIB}/adapters/mini-server-adapter")" = "755" ] || fail "Mini-server adapter mode mismatch"
[ "$(stat -c '%a' "${BROKER_ETC}/tools.d/mini-server.yaml")" = "644" ] || fail "Mini-server registry mode mismatch"

expected_sudo="${BROKER_USER} ALL=(${ADAPTER_USER}) NOPASSWD: ${BROKER_LIB}/adapters/mini-server-adapter \"\""
[ -f "${SUDOERS_FILE}" ] && [ ! -L "${SUDOERS_FILE}" ] || fail "Mini-server sudoers policy missing or symlinked"
[ "$(cat "${SUDOERS_FILE}")" = "${expected_sudo}" ] || fail "Mini-server sudoers policy mismatch"
[ "$(stat -c '%U:%G:%a' "${SUDOERS_FILE}")" = "root:root:440" ] || fail "Mini-server sudoers metadata mismatch"
visudo -c >/dev/null || fail "Sudoers configuration invalid"

state="${BROKER_STATE}/install-state.json"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1], encoding="utf-8")); assert s["commit"]==sys.argv[2]; assert s["stage"]=="4D.3"' \
    "${state}" "${COMMIT_SHA}" || fail "4D.3 install state mismatch"
legacy_snapshot="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["legacy_snapshot"])' "${state}")"
case "$(realpath -e -- "${legacy_snapshot}")" in
    "${BROKER_STATE}/migrations/"*) ;;
    *) fail "Install state references an untrusted migration snapshot" ;;
esac
sha256sum -c --status "${legacy_snapshot}/BASE-CANVAS.sha256" || fail "Base Canvas files changed"

request_health='{"version":1,"request_id":"123e4567-e89b-12d3-a456-426614174031","tool":"mini_server.health","params":{}}'
response="$(printf '%s' "${request_health}" | runuser -u "${BROKER_USER}" -- \
    env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /usr/bin/python3 "${BROKER_LIB}/broker_core.py")" || fail "Installed mini-server health process-path failed"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["status"]=="ok"; c=r["result"]["canvas_service"]; assert c["active_state"]=="active"; assert c["sub_state"]=="running"; assert c["http_status"]==200' \
    "${response}" || fail "Mini-server health contract mismatch"

request_fs='{"version":1,"request_id":"123e4567-e89b-12d3-a456-426614174032","tool":"mini_server.filesystem_usage","params":{"path":"/srv/openhands-agent"}}'
response="$(printf '%s' "${request_fs}" | runuser -u "${BROKER_USER}" -- \
    env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /usr/bin/python3 "${BROKER_LIB}/broker_core.py")" || fail "Installed filesystem usage process-path failed"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["status"]=="ok"; assert r["result"]["path"]=="/srv/openhands-agent"; assert r["result"]["total_bytes"]>0' \
    "${response}" || fail "Filesystem usage contract mismatch"

request_bad='{"version":1,"request_id":"123e4567-e89b-12d3-a456-426614174033","tool":"mini_server.filesystem_usage","params":{"path":"/etc"}}'
if printf '%s' "${request_bad}" | runuser -u "${BROKER_USER}" -- \
    env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /usr/bin/python3 "${BROKER_LIB}/broker_core.py" >/dev/null 2>&1; then
    fail "Unlisted filesystem path was accepted"
fi

ok "4D.3 mini-server Level A validation passed"
