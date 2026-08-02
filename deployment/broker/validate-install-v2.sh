#!/usr/bin/bash
# Read-only validation of an installed Broker v2 foundation.
set -euo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly BROKER_USER="openhands-broker"
readonly BROKER_LIB="/usr/local/lib/openhands-broker"
readonly BROKER_ETC="/etc/openhands-broker"
readonly BROKER_STATE="/var/lib/openhands-broker"
readonly CLIENT_KEY="/srv/openhands-agent/secrets/broker-mini-server.key"
readonly CLIENT_PUBLIC_KEY="/srv/openhands-agent/secrets/broker-mini-server.key.pub"
readonly -a ADAPTERS=(mini-server vps n8n github nextcloud notion amnesia)
COMMIT_SHA="${1:-}"

fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
ok() { printf '  [OK] %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || fail "Run with sudo"
[[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "A full commit SHA is required"
id "${BROKER_USER}" >/dev/null 2>&1 || fail "Broker user missing"
[ "$(id -nG "${BROKER_USER}")" = "${BROKER_USER}" ] || fail "Broker core has unexpected group memberships"
runuser -u "${BROKER_USER}" -- test ! -r "${CLIENT_KEY}" \
    || fail "Broker core can read the protected client private key"

for path in \
    "${BROKER_LIB}/broker_core.py" \
    "${BROKER_LIB}/bin/broker-launcher" \
    "${BROKER_LIB}/adapters/core-adapter" \
    "${BROKER_ETC}/tools.d/core.yaml"; do
    [ -f "${path}" ] && [ ! -L "${path}" ] || fail "Installed artifact missing or symlinked: ${path}"
    [ "$(stat -c '%U:%G' "${path}")" = "root:root" ] || fail "Installed artifact not root-owned: ${path}"
done
[ -L "${BROKER_LIB}/tools.d" ] \
    && [ "$(readlink "${BROKER_LIB}/tools.d")" = "${BROKER_ETC}/tools.d" ] \
    || fail "Registry link is not fixed to the root-owned registry"
cmp -s deployment/broker/broker_core.py "${BROKER_LIB}/broker_core.py" \
    || fail "Installed broker core differs from approved source"
cmp -s deployment/broker/bin/broker-launcher "${BROKER_LIB}/bin/broker-launcher" \
    || fail "Installed launcher differs from approved source"
cmp -s deployment/broker/adapters/core-adapter "${BROKER_LIB}/adapters/core-adapter" \
    || fail "Installed core adapter differs from approved source"
cmp -s deployment/broker/tools.d/core.yaml "${BROKER_ETC}/tools.d/core.yaml" \
    || fail "Installed registry differs from approved source"

[ ! -e /etc/sudoers.d/openhands-broker ] || fail "Legacy sudoers still exists"
sudo -l -U "${BROKER_USER}" 2>/dev/null | grep -q 'NOPASSWD' && fail "Broker retains a NOPASSWD grant"

for adapter in "${ADAPTERS[@]}"; do
    user="openhands-adapter-${adapter}"
    id "${user}" >/dev/null 2>&1 || fail "Adapter identity missing: ${user}"
    [ "$(getent passwd "${user}" | cut -d: -f6-7)" = "/nonexistent:/usr/sbin/nologin" ] \
        || fail "Adapter account contract mismatch: ${user}"
    [ "$(stat -c '%U:%G:%a' "${BROKER_ETC}/secrets.d/${adapter}")" = "root:${user}:750" ] \
        || fail "Adapter secret boundary mismatch: ${adapter}"
    [ "$(stat -c '%U:%G:%a' "${BROKER_STATE}/adapters/${adapter}")" = "${user}:${user}:700" ] \
        || fail "Adapter state boundary mismatch: ${adapter}"
    runuser -u "${user}" -- test -x "${BROKER_STATE}/adapters/${adapter}" \
        || fail "Adapter cannot traverse its own state boundary: ${adapter}"
    runuser -u "${user}" -- test -x "${BROKER_ETC}/secrets.d/${adapter}" \
        || fail "Adapter cannot traverse its own credential boundary: ${adapter}"
    runuser -u "${user}" -- test ! -r "${CLIENT_KEY}" \
        || fail "Adapter can read the Canvas broker client key: ${adapter}"
done
[ "$(stat -c '%U:%G:%a' "${BROKER_STATE}")" = "root:root:711" ] \
    || fail "Broker state parent boundary mismatch"
[ "$(stat -c '%U:%G:%a' "${BROKER_STATE}/adapters")" = "root:root:711" ] \
    || fail "Adapter state parent boundary mismatch"
for adapter in "${ADAPTERS[@]}"; do
    user="openhands-adapter-${adapter}"
    for other in "${ADAPTERS[@]}"; do
        [ "${adapter}" = "${other}" ] && continue
        if runuser -u "${user}" -- test -x "${BROKER_STATE}/adapters/${other}"; then
            fail "Adapter state isolation failed: ${adapter} -> ${other}"
        fi
        if runuser -u "${user}" -- test -r "${BROKER_ETC}/secrets.d/${other}"; then
            fail "Adapter credential isolation failed: ${adapter} -> ${other}"
        fi
    done
done

[ "$(stat -c '%U:%G:%a' /home/openhands-broker)" = "root:root:711" ] \
    || fail "Broker home boundary mismatch"
[ "$(stat -c '%U:%G:%a' /home/openhands-broker/.ssh)" = "root:root:711" ] \
    || fail "Broker SSH directory boundary mismatch"
[ "$(stat -c '%U:%G:%a' /home/openhands-broker/.ssh/authorized_keys)" = "root:${BROKER_USER}:440" ] \
    || fail "authorized_keys boundary mismatch"
derived_public="$(ssh-keygen -y -f "${CLIENT_KEY}")"
expected_auth="from=\"10.89.0.2\",restrict,command=\"${BROKER_LIB}/bin/broker-launcher\" ${derived_public}"
[ "$(cat /home/openhands-broker/.ssh/authorized_keys)" = "${expected_auth}" ] \
    || fail "authorized_keys forced-command/source policy mismatch"
host_public="$(awk 'NF >= 2 {print $1 " " $2; exit}' /etc/ssh/ssh_host_ed25519_key.pub)"
[ "$(cat "${BROKER_ETC}/client_known_hosts")" = "10.89.0.1 ${host_public}" ] \
    || fail "Pinned host trust mismatch"
[ "$(stat -c '%u:%g:%a' "${BROKER_ETC}/client_known_hosts")" = "0:10001:640" ] \
    || fail "Pinned host trust boundary mismatch"

for path in /run/openhands-broker/approvals /run/openhands-broker/inflight /run/openhands-broker/consumed; do
    [ "$(stat -c '%U:%G:%a' "${path}")" = "root:root:700" ] || fail "Level C directory boundary mismatch: ${path}"
done

[ "$(stat -c '%u:%g:%a' "${CLIENT_KEY}")" = "0:10001:640" ] \
    || fail "Preserved private key metadata changed"
[ "$(ssh-keygen -y -f "${CLIENT_KEY}")" = "$(awk 'NF >= 2 {print $1 " " $2; exit}' "${CLIENT_PUBLIC_KEY}")" ] \
    || fail "Preserved broker keypair mismatch"

sshd -t || fail "sshd configuration invalid"
effective="$(sshd -T -C user=openhands-broker,host=mini-server,addr=10.89.0.2)"
grep -qx 'forcecommand /usr/local/lib/openhands-broker/bin/broker-launcher' <<<"${effective}" \
    || fail "Effective forced command mismatch"
grep -qx 'disableforwarding yes' <<<"${effective}" || fail "Forwarding is not disabled"
grep -qx 'permittty no' <<<"${effective}" || fail "TTY is not disabled"

request='{"version":1,"request_id":"123e4567-e89b-12d3-a456-426614174000","tool":"core.capabilities","params":{}}'
response="$(printf '%s' "${request}" | runuser -u "${BROKER_USER}" -- \
    env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /usr/bin/python3 "${BROKER_LIB}/broker_core.py")" || fail "Installed Broker Core process-path failed"
python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"] == "ok"; assert r["result"]["level_b_enabled"] is False; assert r["result"]["level_c_enabled"] is False' \
    <<<"${response}" || fail "Installed capabilities contract mismatch"

python3 -c 'import json,sys; state=json.load(open(sys.argv[1], encoding="utf-8")); assert state["commit"] == sys.argv[2]' \
    "${BROKER_STATE}/install-state.json" "${COMMIT_SHA}" || fail "Install state mismatch"
snapshot="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["legacy_snapshot"])' \
    "${BROKER_STATE}/install-state.json")"
case "$(realpath -e -- "${snapshot}")" in
    "${BROKER_STATE}/migrations/"*) ;;
    *) fail "Install state references an untrusted snapshot" ;;
esac
ok "Broker v2 installation validation passed"
