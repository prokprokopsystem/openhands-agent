#!/usr/bin/bash
# Remove only v2 broker artifacts. Preserved client keys and base Canvas are untouched.
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly STATE_ROOT="/var/lib/openhands-broker"
readonly -a ADAPTERS=(mini-server vps n8n github nextcloud notion amnesia)
[ "$(id -u)" -eq 0 ] || { echo '[FAIL] Run with sudo' >&2; exit 1; }
[ "${1:-}" = "--confirm" ] || { echo "[FAIL] Usage: sudo $0 --confirm" >&2; exit 1; }
[ -f "${STATE_ROOT}/install-state.json" ] && [ ! -L "${STATE_ROOT}/install-state.json" ] \
    || { echo '[FAIL] Broker v2 install marker missing' >&2; exit 1; }
python3 -c 'import json,sys; s=json.load(open(sys.argv[1], encoding="utf-8")); assert s["version"] == 1' \
    "${STATE_ROOT}/install-state.json" || { echo '[FAIL] Invalid install marker' >&2; exit 1; }

rm -f -- /etc/sudoers.d/openhands-broker /etc/ssh/sshd_config.d/99-openhands-broker.conf
rm -rf -- /usr/local/lib/openhands-broker /etc/openhands-broker /home/openhands-broker /run/openhands-broker
id openhands-broker >/dev/null 2>&1 && userdel openhands-broker
for adapter in "${ADAPTERS[@]}"; do
    user="openhands-adapter-${adapter}"
    id "${user}" >/dev/null 2>&1 && userdel "${user}"
done
rm -f -- "${STATE_ROOT}/install-state.json"
rm -rf -- "${STATE_ROOT}/adapters"
sshd -t
systemctl reload ssh.service
logger --tag openhands-broker-setup -- '{"event":"BROKER_V2_UNINSTALLED"}'
printf '  [OK] Broker v2 artifacts removed; migrations and protected client key files preserved\n'
