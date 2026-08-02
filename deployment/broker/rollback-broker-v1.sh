#!/usr/bin/bash
# Restore the exact root-only v1 snapshot created by install-broker-v2.sh.
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly STATE_ROOT="/var/lib/openhands-broker"
readonly BROKER_LIB="/usr/local/lib/openhands-broker"
readonly BROKER_ETC="/etc/openhands-broker"
readonly BROKER_HOME="/home/openhands-broker"
readonly SUDOERS_FILE="/etc/sudoers.d/openhands-broker"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/99-openhands-broker.conf"
readonly -a ADAPTERS=(mini-server vps n8n github nextcloud notion amnesia)
SNAPSHOT="${1:-}"
CONFIRM="${2:-}"

fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "Run with sudo"
[ "${CONFIRM}" = "--confirm" ] || fail "Usage: sudo $0 <snapshot-path> --confirm"
[ -d "${SNAPSHOT}" ] && [ ! -L "${SNAPSHOT}" ] || fail "Snapshot is not a directory"
resolved="$(realpath -e -- "${SNAPSHOT}")"
case "${resolved}" in
    "${STATE_ROOT}/migrations/"*) ;;
    *) fail "Snapshot is outside the trusted migrations directory" ;;
esac
[ "$(stat -c '%U:%G:%a' "${resolved}")" = "root:root:700" ] || fail "Snapshot ownership/mode mismatch"
[ "$(cat "${resolved}/FORMAT")" = "openhands-broker-v1-snapshot" ] || fail "Unknown snapshot format"
for path in lib etc home sudoers sshd-dropin passwd group; do
    [ -e "${resolved}/${path}" ] || fail "Incomplete snapshot: ${path}"
done

sshd_candidate="$(mktemp /run/openhands-rollback-sshd.XXXXXX)"
cat /etc/ssh/sshd_config "${resolved}/sshd-dropin" > "${sshd_candidate}"
sshd -t -f "${sshd_candidate}" || fail "Snapshot sshd policy is invalid"
rm -f "${sshd_candidate}"

rm -rf -- "${BROKER_LIB}" "${BROKER_ETC}" "${BROKER_HOME}"
cp -a "${resolved}/lib" "${BROKER_LIB}"
cp -a "${resolved}/etc" "${BROKER_ETC}"
cp -a "${resolved}/home" "${BROKER_HOME}"
cp -a "${resolved}/sudoers" "${SUDOERS_FILE}"
cp -a "${resolved}/sshd-dropin" "${SSHD_DROPIN}"
rm -f -- "${STATE_ROOT}/install-state.json"
rm -rf -- /run/openhands-broker
for adapter in "${ADAPTERS[@]}"; do
    user="openhands-adapter-${adapter}"
    id "${user}" >/dev/null 2>&1 && userdel "${user}"
done
visudo -cf "${SUDOERS_FILE}" >/dev/null
sshd -t
systemctl reload ssh.service
logger --tag openhands-broker-setup -- '{"event":"ROLLBACK_TO_FROZEN_V1"}'
printf '  [OK] Frozen v1 broker snapshot restored; protected client key files were untouched\n'
