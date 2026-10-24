#!/usr/bin/env bash
# Переключение OpenHands Canvas на производный образ с PDF-инструментами.
# Меняет ТОЛЬКО строку image: в compose.yaml и перезапускает ТОЛЬКО openhands-agent.service.
# Сохраняет бэкап compose, проверяет compose, ждёт healthy и при неуспехе откатывается.
#
# Запуск владельцем (нужен root):
#   sudo bash /srv/openhands-agent/build-pdf-tools/switch-pdf-image.sh
set -euo pipefail

COMPOSE=/srv/openhands-agent/deployment/compose.yaml
SERVICE=openhands-agent.service
OLD_IMAGE="openhands-agent-canvas-ssh:1.6.1-restored"
NEW_IMAGE="openhands-agent-canvas-ssh:1.6.1-restored-pdftools"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BAK="${COMPOSE}.bak-${TS}"

log() { echo "[switch $(date -u +%H:%M:%SZ)] $*"; }

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: запустите через sudo"; exit 2; }
[[ -f "$COMPOSE" ]] || { echo "ERROR: нет $COMPOSE"; exit 3; }
docker image inspect "$NEW_IMAGE" >/dev/null 2>&1 || { echo "ERROR: нет образа $NEW_IMAGE"; exit 4; }

log "бэкап compose -> $BAK"
cp -a "$COMPOSE" "$BAK"

log "установка image reference -> $NEW_IMAGE"
sed -i "s#^\( *image: *\)${OLD_IMAGE}\$#\1${NEW_IMAGE}#" "$COMPOSE"
if ! grep -q "image: ${NEW_IMAGE}" "$COMPOSE"; then
  log "sed не применился — восстанавливаю compose"
  cp -a "$BAK" "$COMPOSE"
  exit 5
fi

log "проверка compose"
if ! docker compose -f "$COMPOSE" config --quiet; then
  log "compose невалиден — восстанавливаю"
  cp -a "$BAK" "$COMPOSE"
  exit 6
fi

log "перезапуск $SERVICE (Canvas кратковременно недоступен ~30-90 c)"
systemctl restart "$SERVICE" || true

ok=0
for i in $(seq 1 100); do
  run=$(docker inspect -f '{{.State.Status}}' openhands-agent 2>/dev/null || echo none)
  st=$(docker inspect -f '{{.State.Health.Status}}' openhands-agent 2>/dev/null || echo none)
  if [[ "$run" == "running" && "$st" == "healthy" ]]; then ok=1; break; fi
  sleep 3
done

if [[ "$ok" -eq 1 ]]; then
  log "HEALTHY. Config.Image=$(docker inspect -f '{{.Config.Image}}' openhands-agent) ImageID=$(docker inspect -f '{{.Image}}' openhands-agent)"
  log "SUCCESS"
  exit 0
fi

log "контейнер не стал healthy — ОТКАТ на предыдущий образ"
cp -a "$BAK" "$COMPOSE"
systemctl restart "$SERVICE" || true
log "откат выполнен, Canvas поднимается на $OLD_IMAGE"
exit 7
