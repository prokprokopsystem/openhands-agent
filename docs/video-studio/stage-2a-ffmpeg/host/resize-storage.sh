#!/usr/bin/env bash
# Расширение хранилища. Работает на смонтированной файловой системе, без
# остановки контейнеров и без перезагрузки.
#
#   sudo ./host/resize-storage.sh              # показать план
#   sudo ./host/resize-storage.sh --apply --size-gib 60
#
# Уменьшение не поддерживается: оно требует размонтирования и проверки ФС.
set -euo pipefail

IMAGE="${IMAGE:-/srv/video-studio-data.img}"
MOUNT="${MOUNT:-/srv/video-studio-data}"
SIZE_GIB=""

APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --size-gib) SIZE_GIB="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
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
[ -n "$SIZE_GIB" ] || die "укажите новый размер: --size-gib N"
findmnt -no TARGET "$MOUNT" >/dev/null 2>&1 || die "$MOUNT не смонтирован"

loop=$(findmnt -no SOURCE "$MOUNT")
case "$loop" in
  /dev/loop*) ;;
  *) die "$MOUNT смонтирован не через loop ($loop) — сценарий не тот" ;;
esac

current=$(df -BG --output=size "$MOUNT" | awk 'NR==2{gsub(/G/,"",$1); print $1}')
[ "$SIZE_GIB" -gt "$current" ] || die "новый размер $SIZE_GIB GiB не больше текущего $current GiB"

host_free=$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,"",$1); print $1}')
[ "$host_free" -ge $(( SIZE_GIB - current + 10 )) ] || \
  die "на / свободно $host_free GiB, расширение требует ещё $(( SIZE_GIB - current )) GiB плюс запас 10 GiB"

printf 'Текущий размер: %s GiB, новый: %s GiB, loop: %s\n' "$current" "$SIZE_GIB" "$loop"
printf 'На / свободно: %s GiB\n' "$host_free"

run truncate -s "${SIZE_GIB}G" "$IMAGE"
run losetup -c "$loop"
run resize2fs "$loop"
run sh -c "printf '%s\n' $SIZE_GIB > $MOUNT/.storage-size-gib"

if [ "$APPLY" != "1" ]; then
  printf '\nЭто была примерка. Ничего не изменено.\n'
  exit 0
fi

printf '\n'
df -h "$MOUNT" | tail -1
printf 'ПРОЙДЕНО: размер увеличен, данные не перемещались.\n'
printf 'Маркер .storage-size-gib: %s\n' "$(cat "$MOUNT/.storage-size-gib" 2>/dev/null || echo нет)"
