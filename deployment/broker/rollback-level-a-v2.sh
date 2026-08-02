#!/usr/bin/bash
# Manual rollback of the exact 4D.3 update snapshot. Preserves the snapshot.
set -euo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly BROKER_LIB="/usr/local/lib/openhands-broker"
readonly BROKER_ETC="/etc/openhands-broker"
readonly BROKER_STATE="/var/lib/openhands-broker"
readonly INSTALL_STATE="${BROKER_STATE}/install-state.json"
readonly SUDOERS_FILE="/etc/sudoers.d/openhands-broker-v2-mini-server"
SNAPSHOT_INPUT="${1:-}"

fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
ok() { printf '  [OK] %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || fail "Run with sudo"
[ "$#" -eq 2 ] && [ "${2}" = "--confirm" ] \
    || fail "Usage: $0 /var/lib/openhands-broker/updates/<exact-4d3-snapshot> --confirm"
[ -f "${INSTALL_STATE}" ] && [ ! -L "${INSTALL_STATE}" ] || fail "Broker install state missing or symlinked"
SNAPSHOT="$(realpath -e -- "${SNAPSHOT_INPUT}")" || fail "4D.3 snapshot not found"
case "${SNAPSHOT}" in
    "${BROKER_STATE}/updates/"*-4d3-to-*) ;;
    *) fail "Snapshot is outside the trusted 4D.3 update directory" ;;
esac
recorded="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("level_a_update_snapshot", ""))' "${INSTALL_STATE}")"
[ "${SNAPSHOT}" = "${recorded}" ] || fail "Snapshot does not match current 4D.3 install state"
for file in broker_core.py core.yaml install-state.json; do
    [ -f "${SNAPSHOT}/${file}" ] && [ ! -L "${SNAPSHOT}/${file}" ] || fail "4D.3 snapshot is incomplete or symlinked"
done

legacy_snapshot="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["legacy_snapshot"])' "${SNAPSHOT}/install-state.json")"
case "$(realpath -e -- "${legacy_snapshot}")" in
    "${BROKER_STATE}/migrations/"*) ;;
    *) fail "Snapshot references an untrusted 4D.2 migration snapshot" ;;
esac
sha256sum -c --status "${legacy_snapshot}/BASE-CANVAS.sha256" || fail "Base Canvas files changed; refusing rollback"

install -o root -g root -m 0755 "${SNAPSHOT}/broker_core.py" "${BROKER_LIB}/broker_core.py"
install -o root -g root -m 0644 "${SNAPSHOT}/core.yaml" "${BROKER_ETC}/tools.d/core.yaml"
install -o root -g root -m 0600 "${SNAPSHOT}/install-state.json" "${INSTALL_STATE}"
rm -f -- "${BROKER_LIB}/adapters/mini-server-adapter" \
    "${BROKER_ETC}/tools.d/mini-server.yaml" "${SUDOERS_FILE}"
visudo -c >/dev/null || fail "Sudoers invalid after rollback"
sha256sum -c --status "${legacy_snapshot}/BASE-CANVAS.sha256" || fail "Base Canvas files changed during rollback"
logger --tag openhands-broker-setup -- '{"event":"LEVEL_A_ROLLED_BACK"}'
ok "Exact completed 4D.2 broker state restored; 4D.3 snapshot preserved"
