#!/usr/bin/env bash
# Безопасное удаление хранилища видеостудии.
#
#   sudo ./host/remove-storage.sh                 # показать план
#   sudo ./host/remove-storage.sh --apply         # удалить (если нет файлов)
#   sudo ./host/remove-storage.sh --apply --force # удалить вместе с файлами
#
# Удаление затрагивает только ресурсы проекта video-studio. Чужие контейнеры,
# образы, тома и сети не трогаются.
set -euo pipefail

IMAGE="${IMAGE:-/srv/video-studio-data.img}"
MOUNT="${MOUNT:-/srv/video-studio-data}"
PROJECT_DIR="${PROJECT_DIR:-/home/igor/video-studio}"
KEEP_EXTRA_GIB="${KEEP_EXTRA_GIB:-1}"

APPLY=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf 'Неизвестный аргумент: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

die() { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$APPLY" = "1" ]; then printf '+ %s\n' "$*"; "$@"
  else printf '  %s\n' "$*"; fi
}

if [ "$APPLY" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "для --apply нужен root: sudo $0 --apply"
fi

if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  used=$(df -BG --output=used "$MOUNT" | awk 'NR==2{gsub(/G/,"",$1); print $1+0}')
  if [ "$used" -gt "$KEEP_EXTRA_GIB" ] && [ "$FORCE" != "1" ]; then
    die "в $MOUNT занято $used GiB; сохраните или удалите данные, либо повторите с --force"
  fi
fi

printf '=== План ===\n'
printf '  остановить контейнеры проекта video-studio (если запущены)\n'
run umount "$MOUNT"
printf '  удалить строку /etc/fstab для %s (с резервной копией)\n' "$MOUNT"
run rm -f "$IMAGE"
run rmdir "$MOUNT"

if [ "$APPLY" != "1" ]; then
  printf '\nЭто была примерка. Ничего не изменено.\n'
  exit 0
fi

printf '\n=== Применение ===\n'
if [ -d "$PROJECT_DIR" ]; then
  ( cd "$PROJECT_DIR" && docker compose down >/dev/null 2>&1 || true )
fi

if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  umount "$MOUNT" || die "не удалось размонтировать: занято процессом"
fi

stamp=$(date +%Y%m%d-%H%M%S)
cp -a /etc/fstab "/etc/fstab.bak-$stamp"
sed -i "\#^$IMAGE #d" /etc/fstab
systemctl daemon-reload
printf 'ИЗМЕНЕНО: /etc/fstab, резервная копия /etc/fstab.bak-%s\n' "$stamp"

rm -f "$IMAGE"
rmdir "$MOUNT" 2>/dev/null || true

printf 'ПРОЙДЕНО: хранилище удалено. Конфигурация проекта в %s не тронута.\n' "$PROJECT_DIR"
