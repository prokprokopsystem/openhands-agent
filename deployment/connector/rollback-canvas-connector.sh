#!/usr/bin/bash
# Restore the exact pre-connector Canvas deployment. Preserves broker and snapshots.
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly BASE="/srv/openhands-agent"
readonly BROKER_STATE="/var/lib/openhands-broker"
readonly CONNECTOR_STATE="${BROKER_STATE}/connector-state.json"
readonly -a CHANGED_FILES=(
    deployment/compose.yaml
    deployment/network/apply-egress-rules.sh
    deployment/network/check-egress.sh
    deployment/network/README.md
    deployment/scripts/validate-runtime.sh
    deployment/scripts/validate-static.sh
)

fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
ok() { printf '  [OK] %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || fail "Run with sudo"
[ "$#" -eq 1 ] && [ "${1}" = "--confirm" ] || fail "Usage: $0 --confirm"
[ -f "${CONNECTOR_STATE}" ] && [ ! -L "${CONNECTOR_STATE}" ] || fail "Connector state missing or symlinked"
SNAPSHOT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["pre_connector_snapshot"])' "${CONNECTOR_STATE}")"
SNAPSHOT="$(realpath -e -- "${SNAPSHOT}")" || fail "Pre-connector snapshot missing"
case "${SNAPSHOT}" in
    "${BROKER_STATE}/connectors/"*-pre-4d4-to-*) ;;
    *) fail "Pre-connector snapshot path is untrusted" ;;
esac
[ -f "${SNAPSHOT}/PRE-CONNECTOR.sha256" ] || fail "Pre-connector manifest missing"

systemctl stop openhands-agent.service
for path in "${CHANGED_FILES[@]}"; do
    [ -f "${SNAPSHOT}/${path}" ] && [ ! -L "${SNAPSHOT}/${path}" ] || fail "Pre-connector snapshot is incomplete"
    cp -a -- "${SNAPSHOT}/${path}" "${BASE}/${path}"
done
rm -rf -- "${BASE}/deployment/connector"
rm -f -- "${CONNECTOR_STATE}"
sha256sum -c --status "${SNAPSHOT}/PRE-CONNECTOR.sha256" || fail "Pre-connector files were not restored exactly"
systemctl start openhands-agent.service
for _ in $(seq 1 60); do
    if systemctl is-active --quiet openhands-agent.service \
        && [ "$(docker inspect --format '{{.State.Health.Status}}' openhands-agent 2>/dev/null || true)" = "healthy" ] \
        && curl -fsS -o /dev/null --max-time 5 http://10.77.0.2:8000/canvas; then
        break
    fi
    sleep 2
done
systemctl is-active --quiet openhands-agent.service || fail "Base Canvas service failed after rollback"
[ "$(docker inspect --format '{{.State.Health.Status}}' openhands-agent)" = "healthy" ] || fail "Base Canvas container failed after rollback"
curl -fsS -o /dev/null --max-time 5 http://10.77.0.2:8000/canvas || fail "Base Canvas HTTP failed after rollback"
logger --tag openhands-broker-setup -- '{"event":"CANVAS_CONNECTOR_ROLLED_BACK"}'
ok "Exact pre-connector Canvas deployment restored; connector snapshot and image preserved"
