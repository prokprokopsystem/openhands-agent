#!/usr/bin/env bash
# Remove only OpenHands firewall jumps and dedicated chains.
set -Eeuo pipefail

SUBNET="10.89.0.0/28"
EGRESS_CHAIN="OPENHANDS-EGRESS"
INPUT_CHAIN="OPENHANDS-INPUT"

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

while iptables -C DOCKER-USER -s "${SUBNET}" -j "${EGRESS_CHAIN}" 2>/dev/null; do
  iptables -D DOCKER-USER -s "${SUBNET}" -j "${EGRESS_CHAIN}"
done
while iptables -C INPUT -s "${SUBNET}" -j "${INPUT_CHAIN}" 2>/dev/null; do
  iptables -D INPUT -s "${SUBNET}" -j "${INPUT_CHAIN}"
done

if iptables -nL "${EGRESS_CHAIN}" >/dev/null 2>&1; then
  iptables -F "${EGRESS_CHAIN}"
  iptables -X "${EGRESS_CHAIN}"
fi
if iptables -nL "${INPUT_CHAIN}" >/dev/null 2>&1; then
  iptables -F "${INPUT_CHAIN}"
  iptables -X "${INPUT_CHAIN}"
fi

echo "OpenHands firewall rules removed."
