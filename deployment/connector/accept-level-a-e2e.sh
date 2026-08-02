#!/usr/bin/bash
# Stage 4D.5 — Canvas UID 10001 to broker Level A acceptance and denials.
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
ok() { printf '  [OK] %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || fail "Run with sudo"
[ "$(docker inspect --format '{{.State.Health.Status}}' openhands-agent)" = "healthy" ] || fail "Canvas container is not healthy"

call_broker() {
    printf '%s' "$1" | docker exec -i -u 10001:10001 openhands-agent /usr/local/bin/openhands-broker-client
}

ping_request='{"version":1,"request_id":"123e4567-e89b-12d3-a456-426614174050","tool":"core.ping","params":{}}'
ping_response="$(call_broker "${ping_request}")" || fail "Canvas core.ping failed"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["status"]=="ok"; assert r["result"]["pong"] is True' \
    "${ping_response}" || fail "Canvas core.ping response mismatch"

health_request='{"version":1,"request_id":"123e4567-e89b-12d3-a456-426614174051","tool":"mini_server.health","params":{}}'
health_response="$(call_broker "${health_request}")" || fail "Canvas mini_server.health failed"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["status"]=="ok"; c=r["result"]["canvas_service"]; assert c["active_state"]=="active"; assert c["sub_state"]=="running"; assert c["http_status"]==200' \
    "${health_response}" || fail "Canvas mini_server.health response mismatch"

bad_request='{"version":1,"request_id":"123e4567-e89b-12d3-a456-426614174052","tool":"mini_server.filesystem_usage","params":{"path":"/etc"}}'
set +e
bad_response="$(call_broker "${bad_request}")"
bad_rc=$?
set -e
[ "${bad_rc}" -ne 0 ] || fail "Unlisted filesystem path was accepted"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["status"]=="rejected"; assert r["error"]["code"]=="invalid_params"' \
    "${bad_response}" || fail "Invalid path denial response mismatch"

set +e
argument_response="$(docker exec -u 10001:10001 openhands-agent /usr/local/bin/openhands-broker-client core.ping)"
argument_rc=$?
set -e
[ "${argument_rc}" -ne 0 ] || fail "Connector client accepted command-line arguments"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["error"]["code"]=="arguments_forbidden"' \
    "${argument_response}" || fail "Connector argument denial mismatch"

set +e
original_command_response="$(printf '{}' | docker exec -i -u 10001:10001 openhands-agent /usr/bin/ssh \
    -F /dev/null -T -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/openhands-broker/client/client_known_hosts \
    -o GlobalKnownHostsFile=/dev/null -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o PubkeyAuthentication=yes -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 \
    -o ClearAllForwardings=yes -o PermitLocalCommand=no -o RequestTTY=no -o ConnectTimeout=5 \
    -i /run/openhands-broker/client/id_ed25519 openhands-broker@10.89.0.1 id 2>/dev/null)"
original_command_rc=$?
set -e
[ "${original_command_rc}" -ne 0 ] || fail "Forced command accepted SSH_ORIGINAL_COMMAND"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["status"]=="rejected"; assert r["error"]["code"]=="original_command_forbidden"' \
    "${original_command_response}" || fail "SSH_ORIGINAL_COMMAND denial response mismatch"

for request_id in 123e4567-e89b-12d3-a456-426614174050 123e4567-e89b-12d3-a456-426614174051; do
    journalctl -t openhands-broker --since '-5 minutes' --no-pager -o cat | grep -F "${request_id}" | grep -F '"event":"SUCCEEDED"' >/dev/null \
        || fail "Mandatory success audit missing: ${request_id}"
done

ok "4D.5 Canvas to broker Level A end-to-end acceptance passed"
