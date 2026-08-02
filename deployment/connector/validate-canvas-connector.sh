#!/usr/bin/bash
# Read-only state validation plus an audited core.ping through the live Connector.
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly BASE="/srv/openhands-agent"
readonly BROKER_STATE="/var/lib/openhands-broker"
readonly CONNECTOR_STATE="${BROKER_STATE}/connector-state.json"
readonly IMAGE="openhands-agent-canvas-broker:1.6.1-4d4"
COMMIT_SHA="${1:-}"

ok() { printf '  [OK] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run with sudo"
[[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "A full commit SHA is required"
[ "$(git rev-parse HEAD)" = "${COMMIT_SHA}" ] || fail "Checkout HEAD differs from approved commit"
[ -z "$(git status --porcelain)" ] || fail "Checkout is not clean"
[ -f "${CONNECTOR_STATE}" ] && [ ! -L "${CONNECTOR_STATE}" ] || fail "Connector state missing or symlinked"

python3 -c 'import json,sys; s=json.load(open(sys.argv[1], encoding="utf-8")); assert s["stage"]=="4D.4"; assert s["commit"]==sys.argv[2]' \
    "${CONNECTOR_STATE}" "${COMMIT_SHA}" || fail "Connector state contract mismatch"
manifest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["canonical_manifest"])' "${CONNECTOR_STATE}")"
case "$(realpath -e -- "${manifest}")" in
    "${BROKER_STATE}/connectors/"*/CANONICAL-CANVAS.sha256) ;;
    *) fail "Canonical connector manifest path is untrusted" ;;
esac
sha256sum -c --status "${manifest}" || fail "Canonical base + connector files changed"
deployment/broker/validate-level-a-v2.sh "${COMMIT_SHA}" || fail "Installed 4D.3 Level A validation failed under Connector baseline"

systemctl is-active --quiet openhands-agent.service || fail "Canvas service is not active"
for _ in $(seq 1 60); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' openhands-agent 2>/dev/null || true)" = "healthy" ] && break
    sleep 2
done
[ "$(docker inspect --format '{{.State.Health.Status}}' openhands-agent)" = "healthy" ] || fail "Canvas container is not healthy"
[ "$(docker inspect --format '{{.Config.Image}}' openhands-agent)" = "${IMAGE}" ] || fail "Canvas is not using the connector image"
[ "$(docker image inspect --format '{{ index .Config.Labels \"org.openhands.connector.source\" }}' "${IMAGE}")" = "${COMMIT_SHA}" ] \
    || fail "Connector image source label mismatch"

mounts="$(docker inspect --format '{{json .Mounts}}' openhands-agent)"
python3 -c 'import json,sys; m={x["Destination"]:(x["Source"],x["RW"]) for x in json.loads(sys.argv[1])}; assert m["/run/openhands-broker/client/id_ed25519"]==( "/srv/openhands-agent/secrets/openhands-broker-v2/id_ed25519", False); assert m["/run/openhands-broker/client/client_known_hosts"]==( "/etc/openhands-broker/client_known_hosts", False); assert m["/home/openhands/.openhands"]==( "/srv/openhands-agent/config", True); assert m["/projects"]==( "/srv/openhands-agent/work-workspace", True); assert m["/docs"]==( "/srv/openhands-agent/docs", False)' \
    "${mounts}" || fail "Connector mount contract mismatch"

docker exec -u 10001:10001 openhands-agent sh -c \
    'test "$(id -u):$(id -g)" = "10001:10001" && command -v ssh >/dev/null && test -r /run/openhands-broker/client/id_ed25519 && test ! -w /run/openhands-broker/client/id_ed25519 && test -r /run/openhands-broker/client/client_known_hosts && test ! -w /run/openhands-broker/client/client_known_hosts' \
    || fail "Canvas connector identity/file-access contract mismatch"
docker exec -u 10001:10001 openhands-agent python3 -c \
    'import socket; s=socket.create_connection(("10.89.0.1",22),3); s.close()' \
    || fail "Broker SSH endpoint is unreachable from Canvas"

request='{"version":1,"request_id":"123e4567-e89b-12d3-a456-426614174040","tool":"core.ping","params":{}}'
response="$(printf '%s' "${request}" | docker exec -i -u 10001:10001 openhands-agent /usr/local/bin/openhands-broker-client)" \
    || fail "Canvas to broker core.ping transport failed"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["status"]=="ok"; assert r["result"]["pong"] is True; assert r["result"]["protocol_version"]==1' \
    "${response}" || fail "Canvas to broker core.ping response mismatch"

curl -fsS -o /dev/null --max-time 5 http://10.77.0.2:8000/canvas || fail "Canvas HTTP failed after Connector"
iptables -C OPENHANDS-EGRESS -s 10.89.0.2/32 -d 10.89.0.1/32 -p tcp --dport 22 -m conntrack --ctstate NEW -j RETURN >/dev/null \
    || fail "Exact broker egress rule missing"
iptables -C OPENHANDS-INPUT -s 10.89.0.2/32 -d 10.89.0.1/32 -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT >/dev/null \
    || fail "Exact broker input rule missing"
bash "${BASE}/deployment/network/check-egress.sh" || fail "Connector network isolation checks failed"

ok "4D.4 Canvas Connector validation passed"
