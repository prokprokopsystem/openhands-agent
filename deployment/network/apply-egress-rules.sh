#!/usr/bin/env bash
# Apply egress and host-access isolation for OpenHands only.
set -Eeuo pipefail

SUBNET="10.89.0.0/28"
VPS_IP="95.217.239.148"
EGRESS_CHAIN="OPENHANDS-EGRESS"
INPUT_CHAIN="OPENHANDS-INPUT"

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

command -v iptables >/dev/null
iptables -nL DOCKER-USER >/dev/null

# Rebuild dedicated chains so rule order is deterministic.
iptables -N "${EGRESS_CHAIN}" 2>/dev/null || true
iptables -F "${EGRESS_CHAIN}"
iptables -N "${INPUT_CHAIN}" 2>/dev/null || true
iptables -F "${INPUT_CHAIN}"

# Exactly one jump from shared chains.
while iptables -C DOCKER-USER -s "${SUBNET}" -j "${EGRESS_CHAIN}" 2>/dev/null; do
  iptables -D DOCKER-USER -s "${SUBNET}" -j "${EGRESS_CHAIN}"
done
iptables -I DOCKER-USER 1 -s "${SUBNET}" -j "${EGRESS_CHAIN}"

while iptables -C INPUT -s "${SUBNET}" -j "${INPUT_CHAIN}" 2>/dev/null; do
  iptables -D INPUT -s "${SUBNET}" -j "${INPUT_CHAIN}"
done
iptables -I INPUT 1 -s "${SUBNET}" -j "${INPUT_CHAIN}"

# Preserve replies to connections initiated from outside the container.
iptables -A "${EGRESS_CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

# Internal/private destinations are denied before any service allow-list.
# The only permitted host service is the forced-command broker over SSH.
iptables -A "${EGRESS_CHAIN}" -d 10.89.0.1 -p tcp --dport 22 -j RETURN

iptables -A "${EGRESS_CHAIN}" -d 127.0.0.0/8 -j DROP
iptables -A "${EGRESS_CHAIN}" -d 169.254.0.0/16 -j DROP
iptables -A "${EGRESS_CHAIN}" -d 10.0.0.0/8 -j DROP
iptables -A "${EGRESS_CHAIN}" -d 172.16.0.0/12 -j DROP
iptables -A "${EGRESS_CHAIN}" -d 192.168.0.0/16 -j DROP
iptables -A "${EGRESS_CHAIN}" -d 100.64.0.0/10 -j DROP
iptables -A "${EGRESS_CHAIN}" -d "${VPS_IP}/32" -j DROP

# Only public DNS and web traffic are allowed; everything else is denied.
iptables -A "${EGRESS_CHAIN}" -p udp --dport 53 -j RETURN
iptables -A "${EGRESS_CHAIN}" -p tcp --dport 53 -j RETURN
iptables -A "${EGRESS_CHAIN}" -p tcp -m multiport --dports 80,443 -j RETURN
iptables -A "${EGRESS_CHAIN}" -j DROP

# The INPUT path must independently allow the same narrowly scoped broker flow.
iptables -A "${INPUT_CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A "${INPUT_CHAIN}" -d 10.89.0.1 -p tcp --dport 22 -j ACCEPT
iptables -A "${INPUT_CHAIN}" -j DROP

iptables -C DOCKER-USER -s "${SUBNET}" -j "${EGRESS_CHAIN}" >/dev/null
iptables -C INPUT -s "${SUBNET}" -j "${INPUT_CHAIN}" >/dev/null

echo "OpenHands firewall rules applied."
iptables -S "${EGRESS_CHAIN}"
iptables -S "${INPUT_CHAIN}"
