#!/usr/bin/env bash
# Расширение хранилища видеостудии.
#
#   ./host/resize-storage.sh --size-gib 60              # примерка
#   sudo ./host/resize-storage.sh --apply --size-gib 60
#
# Поддерживается только хранилище на loop-образе: там рост — это truncate
# файла плюс resize2fs, без остановки контейнеров.
#
# Хранилище на разделе SSD расширить нельзя: раздел занимает весь диск,
# свободного места за ним нет. Такой случай скрипт распознаёт и отказывает,
# а не пытается что-то менять.
set -euo pipefail

IMAGE="${IMAGE:-/srv/video-studio-data.img}"
MOUNT="${MOUNT:-/srv/video-studio-data}"
SIZE_GIB=""

APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --size-gib) SIZE_GIB="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
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

source=$(findmnt -no SOURCE "$MOUNT")

case "$source" in
  /dev/loop*)
    ;;
  /dev/mapper/*|/dev/dm-*)
    die "хранилище на LVM ($source). Расширение: lvextend -r -L +N G <vg/lv>"
    ;;
  /dev/*)
    if [ -b "$source" ]; then
      die "хранилище на разделе ($source). Раздел занимает весь диск, свободного места за ним нет.
Расширить такой раздел онлайн нельзя. Варианты:
  1. Оставить как есть.
  2. Заменить диск на больший и перенести данные.
  3. Пересоздать разметку с запасом — это уничтожает данные и требует отдельного согласования."
    fi
    die "источник $source не является ни loop-устройством, ни известным блочным устройством"
    ;;
  *)
    die "источник $source не блочное устройство — сценарий не тот"
    ;;
esac

[ -f "$IMAGE" ] || die "нет файла образа $IMAGE — это не loop-хранилище проекта"
[ -b "$IMAGE" ] && die "$IMAGE блочное устройство, ожидался файл образа"

current=$(df -BG --output=size "$MOUNT" | awk 'NR==2{gsub(/G/,"",$1); print $1}')
[ "$SIZE_GIB" -gt "$current" ] || die "новый размер $SIZE_GIB GiB не больше текущего $current GiB"

host_free=$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,"",$1); print $1}')
[ "$host_free" -ge $(( SIZE_GIB - current + 10 )) ] || \
  die "на / свободно $host_free GiB, расширение требует ещё $(( SIZE_GIB - current )) GiB плюс запас 10 GiB"

printf 'Текущий размер: %s GiB, новый: %s GiB, loop: %s\n' "$current" "$SIZE_GIB" "$source"
printf 'На / свободно: %s GiB\n' "$host_free"

run truncate -s "${SIZE_GIB}G" "$IMAGE"
run losetup -c "$source"
run resize2fs "$source"
run sh -c "printf '%s\n' $SIZE_GIB > $MOUNT/.storage-size-gib"

if [ "$APPLY" != "1" ]; then
  printf '\nЭто была примерка. Ничего не изменено.\n'
  exit 0
fi

printf '\n'
df -h "$MOUNT" | tail -1
printf 'ПРОЙДЕНО: размер увеличен, данные не перемещались.\n'
printf 'Маркер .storage-size-gib: %s\n' "$(cat "$MOUNT/.storage-size-gib" 2>/dev/null || echo нет)"
