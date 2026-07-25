#!/usr/bin/env bash
# Show OpenHands service, health, resources, firewall and WireGuard status.
set -u

BASE="/srv/openhands-agent"
COMPOSE_FILE="${BASE}/deployment/compose.yaml"
CONTAINER="openhands-agent"

echo "=== systemd ==="
systemctl --no-pager --full status openhands-agent.service 2>/dev/null || true

echo
echo "=== compose ==="
docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true

echo
echo "=== Docker health ==="
if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  docker inspect --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} started={{.State.StartedAt}}' "${CONTAINER}"
else
  echo "container does not exist"
fi

echo
echo "=== HTTP and internal backend listeners ==="
HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 http://10.77.0.2:8000/canvas 2>/dev/null || true)
echo "WebUI /canvas: HTTP ${HTTP_CODE:-000}"
if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  docker exec "${CONTAINER}" python3 -c "import socket; print('agent-server:18000', socket.create_connection(('127.0.0.1',18000),3).getpeername()); print('automation:18001', socket.create_connection(('127.0.0.1',18001),3).getpeername())" 2>&1 || true
fi

echo
echo "=== resources ==="
docker stats --no-stream "${CONTAINER}" 2>/dev/null || true

echo
echo "=== recent errors ==="
docker logs --tail 100 "${CONTAINER}" 2>&1 | grep -iE 'error|fatal|panic|traceback|failed' | tail -n 30 || echo "none found"

echo
echo "=== firewall ==="
sudo iptables -S OPENHANDS-EGRESS 2>/dev/null || echo "OPENHANDS-EGRESS not installed"
sudo iptables -S OPENHANDS-INPUT 2>/dev/null || echo "OPENHANDS-INPUT not installed"

echo
echo "=== WireGuard ==="
ip -4 addr show dev wg0 2>/dev/null | grep 'inet ' || echo "wg0/10.77.0.2 unavailable"
