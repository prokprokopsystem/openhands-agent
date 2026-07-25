#!/usr/bin/env bash
# Run from the host. Tests network access from inside openhands-agent.
set -Eeuo pipefail

CONTAINER="openhands-agent"
FAIL=0

if ! docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  echo "ERROR: container ${CONTAINER} does not exist" >&2
  exit 1
fi

inside() {
  docker exec "${CONTAINER}" bash -lc "$1"
}

expect_ok() {
  local name="$1" command="$2"
  if inside "${command}" >/dev/null 2>&1; then
    echo "OK   ${name}"
  else
    echo "FAIL ${name}: expected available"
    FAIL=1
  fi
}

expect_blocked() {
  local name="$1" command="$2"
  if inside "${command}" >/dev/null 2>&1; then
    echo "FAIL ${name}: unexpectedly reachable"
    FAIL=1
  else
    echo "OK   ${name}: blocked"
  fi
}

# External services required for model/API use.
expect_ok "DNS resolution" "getent ahostsv4 example.com"
expect_ok "External HTTPS" "curl -sS -o /dev/null --connect-timeout 5 --max-time 10 https://example.com/"

# Internal and non-web destinations must be unreachable.
expect_blocked "AMNESIA 10.77.0.2:8090" "timeout 4 bash -c '</dev/tcp/10.77.0.2/8090'"
expect_blocked "Nextcloud 10.77.0.2:11000" "timeout 4 bash -c '</dev/tcp/10.77.0.2/11000'"
expect_blocked "mini-server SSH 10.77.0.2:22" "timeout 4 bash -c '</dev/tcp/10.77.0.2/22'"
expect_blocked "Docker gateway 10.89.0.1:22" "timeout 4 bash -c '</dev/tcp/10.89.0.1/22'"
expect_blocked "LAN router 192.168.100.1:80" "timeout 4 bash -c '</dev/tcp/192.168.100.1/80'"
expect_blocked "VPS SSH 95.217.239.148:22" "timeout 4 bash -c '</dev/tcp/95.217.239.148/22'"
expect_blocked "Public non-web port github.com:22" "timeout 4 bash -c '</dev/tcp/github.com/22'"

if inside "ip -6 addr show scope global | grep -q inet6" >/dev/null 2>&1; then
  echo "FAIL global IPv6 address is present"
  FAIL=1
else
  echo "OK   IPv6 disabled/no global address"
fi

# WebUI is tested from the host/WireGuard side, not from the isolated container.
HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 http://10.77.0.2:8000/canvas || true)
if [[ "${HTTP_CODE}" =~ ^(200|301|302|307|308)$ ]]; then
  echo "OK   WebUI through WireGuard: HTTP ${HTTP_CODE}"
else
  echo "FAIL WebUI through WireGuard: HTTP ${HTTP_CODE:-000}"
  FAIL=1
fi

exit "${FAIL}"
