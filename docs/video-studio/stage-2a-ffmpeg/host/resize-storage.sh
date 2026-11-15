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
#
# Пути заданы константами: подмена IMAGE через окружение означала бы truncate
# произвольного файла под root.
set -euo pipefail

readonly IMAGE="/srv/video-studio-data.img"
readonly MOUNT="/srv/video-studio-data"

APPLY=0
SIZE_GIB=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --size-gib)
      [ $# -ge 2 ] || { printf 'ОТКАЗ: --size-gib требует значение\n' >&2; exit 2; }
      SIZE_GIB="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) printf 'ОТКАЗ: неизвестный аргумент %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'ОТКАЗ: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

if [ "$APPLY" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "для --apply нужен root: sudo $0 --apply"
fi

stage() {
  local desc="$1" fn="$2"
  if [ "$APPLY" = "1" ]; then
    printf '+ %s\n' "$desc"
    "$fn"
  else
    printf '  %s\n' "$desc"
  fi
}

do_grow() {
  truncate -s "${SIZE_GIB}G" "$IMAGE" || die "truncate не удался"
  losetup -c "$source_loop" || die "losetup -c не удался"
  resize2fs "$source_loop" || die "resize2fs не удался"
}

do_marker() {
  printf '%s\n' "$SIZE_GIB" > "$MOUNT/.storage-size-gib"
  chmod 0444 "$MOUNT/.storage-size-gib"
}

[ -n "$SIZE_GIB" ] || die "укажите новый размер: --size-gib N"
# Размер — только цифры: значение уходит в truncate и в имя файла маркера.
case "$SIZE_GIB" in
  ''|*[!0-9]*) die "--size-gib должно быть целым числом, получено '$SIZE_GIB'" ;;
esac
[ "$SIZE_GIB" -ge 1 ] && [ "$SIZE_GIB" -le 4096 ] || \
  die "--size-gib вне разумных границ: $SIZE_GIB (допустимо 1..4096)"

findmnt -no TARGET "$MOUNT" >/dev/null 2>&1 || die "$MOUNT не смонтирован"
source_loop=$(findmnt -no SOURCE "$MOUNT")

case "$source_loop" in
  /dev/loop*) : ;;
  /dev/mapper/*|/dev/dm-*)
    die "хранилище на LVM ($source_loop). Расширение: lvextend -r -L +N G <vg/lv>" ;;
  /dev/*)
    if [ -b "$source_loop" ]; then
      die "хранилище на разделе ($source_loop). Раздел занимает весь диск, свободного места за ним нет.
Расширить такой раздел онлайн нельзя. Варианты:
  1. Оставить как есть.
  2. Заменить диск на больший и перенести данные.
  3. Пересоздать разметку с запасом — это уничтожает данные и требует отдельного согласования."
    fi
    die "источник $source_loop не блочное устройство" ;;
  *) die "источник $source_loop не блочное устройство — сценарий не тот" ;;
esac

[ -f "$IMAGE" ] || die "нет файла образа $IMAGE — это не loop-хранилище проекта"
[ -b "$IMAGE" ] && die "$IMAGE блочное устройство, ожидался файл образа"

current=$(df -BG --output=size "$MOUNT" | awk 'NR==2{gsub(/G/,"",$1); print $1}')
# Повторный запуск с тем же размером — не ошибка и не повод что-то делать.
if [ "$SIZE_GIB" -le "$current" ]; then
  say "УЖЕ ТАКОЙ РАЗМЕР: $MOUNT — $current GiB, запрошено $SIZE_GIB GiB. Изменений не требуется."
  exit 0
fi

host_free=$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,"",$1); print $1}')
[ "$host_free" -ge $(( SIZE_GIB - current + 10 )) ] || \
  die "на / свободно $host_free GiB, расширение требует ещё $(( SIZE_GIB - current )) GiB плюс запас 10 GiB"

step "1. Параметры"
say "  текущий размер: $current GiB"
say "  новый размер:   $SIZE_GIB GiB"
say "  loop:           $source_loop"
say "  свободно на /:  $host_free GiB"

step "2. План"
stage "truncate -s ${SIZE_GIB}G $IMAGE, losetup -c, resize2fs $source_loop" do_grow
stage "обновить маркер $MOUNT/.storage-size-gib на $SIZE_GIB GiB" do_marker

if [ "$APPLY" != "1" ]; then
  printf '\nЭто была примерка. Ничего не изменено.\n'
  exit 0
fi

say ""
df -h "$MOUNT" | tail -1
say "ПРОЙДЕНО: размер увеличен, данные не перемещались."
say "Маркер .storage-size-gib: $(cat "$MOUNT/.storage-size-gib" 2>/dev/null || echo нет)"
