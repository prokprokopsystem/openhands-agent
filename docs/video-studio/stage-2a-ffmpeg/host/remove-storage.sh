#!/usr/bin/env bash
# Демонтаж хранилища видеостудии. Данные по умолчанию НЕ удаляются.
#
#   ./host/remove-storage.sh                          # примерка
#   sudo ./host/remove-storage.sh --apply             # снять точку монтирования и fstab
#   sudo ./host/remove-storage.sh --apply --delete-image   # плюс удалить файл образа
#
# Скрипт размонтирует хранилище и убирает его запись из /etc/fstab. Что было
# источником — файл образа или раздел диска — решается по фактическому
# состоянию, а не по настройке:
#   * размонтировать и убрать fstab можно всегда;
#   * удалить данные можно только для файла-образа и только с --delete-image;
#   * блочное устройство не стирается никогда: раздел с видео удаляется
#     осознанно, вручную, после отдельного решения.
set -euo pipefail

MOUNT="${MOUNT:-/srv/video-studio-data}"
IMAGE="${IMAGE:-/srv/video-studio-data.img}"
PROJECT_DIR="${PROJECT_DIR:-/home/igor/video-studio}"
KEEP_EXTRA_GIB="${KEEP_EXTRA_GIB:-1}"

APPLY=0
FORCE=0
DELETE_IMAGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    --delete-image) DELETE_IMAGE=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
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

# Источник определяем по факту: после размонтирования findmnt уже не поможет,
# поэтому выясняем заранее.
source=""
if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  source=$(findmnt -no SOURCE "$MOUNT")
fi

is_block=0
if [ -n "$source" ] && [ -b "$source" ]; then
  case "$source" in
    /dev/loop*) is_block=0 ;;   # loop тоже блочное, но это образ проекта
    *) is_block=1 ;;
  esac
fi

printf '=== Состояние ===\n'
printf 'точка:    %s (%s)\n' "$MOUNT" "$(findmnt -no TARGET "$MOUNT" >/dev/null 2>&1 && echo смонтирована || echo не смонтирована)"
printf 'источник: %s\n' "${source:-неизвестен}"
printf 'тип:      %s\n' "$([ "$is_block" = "1" ] && echo 'раздел диска — данные сохранятся' || echo 'файл образа или неизвестно')"

if [ -n "$source" ] && df -BG --output=used "$MOUNT" >/dev/null 2>&1; then
  used=$(df -BG --output=used "$MOUNT" | awk 'NR==2{gsub(/G/,"",$1); print $1+0}')
  if [ "$used" -gt "$KEEP_EXTRA_GIB" ] && [ "$FORCE" != "1" ]; then
    die "в $MOUNT занято $used GiB; сохраните данные, либо повторите с --force (только для файла-образа)"
  fi
fi

if [ "$DELETE_IMAGE" = "1" ] && [ "$is_block" = "1" ]; then
  die "--delete-image для раздела диска запрещён: устройство не стирается скриптом"
fi

printf '\n=== План ===\n'
printf '  остановить контейнеры проекта video-studio (если запущены)\n'
run umount "$MOUNT"
printf '  удалить строку /etc/fstab для %s (по точке монтирования, с резервной копией)\n' "$MOUNT"
if [ "$DELETE_IMAGE" = "1" ]; then
  printf '  удалить файл образа %s\n' "$IMAGE"
else
  printf '  файл образа не удаляется (для удаления нужен --delete-image)\n'
fi
printf '  блочные устройства не стираются никогда\n'

if [ "$APPLY" != "1" ]; then
  printf '\nЭто была примерка. Ничего не изменено.\n'
  exit 0
fi

printf '\n=== Применение ===\n'
if [ -d "$PROJECT_DIR" ]; then
  ( cd "$PROJECT_DIR" && docker compose down >/dev/null 2>&1 || true )
fi

if findmnt -no TARGET "$MOUNT" >/dev/null 2>&1; then
  umount "$MOUNT" || die "не удалось размонтировать: занято процессом. Найдите держателя: fuser -vm $MOUNT"
fi

stamp=$(date +%Y%m%d-%H%M%S)
cp -a /etc/fstab "/etc/fstab.bak-$stamp"
# Ищем по точке монтирования: путь к образу у loop-хранилища и UUID у раздела
# не совпадают, а точка монтирования одна и та же.
sed -i "\\# $MOUNT #d" /etc/fstab
systemctl daemon-reload
printf 'ИЗМЕНЕНО: /etc/fstab, резервная копия /etc/fstab.bak-%s\n' "$stamp"

if [ "$DELETE_IMAGE" = "1" ]; then
  # Удаляем только обычный файл. Каталог, символьная ссылка или устройство
  # здесь означают ошибку в настройках, и rm может сделать не то.
  if [ -f "$IMAGE" ] && [ ! -L "$IMAGE" ]; then
    rm -f "$IMAGE"
    printf 'ИЗМЕНЕНО: удалён файл образа %s\n' "$IMAGE"
  else
    printf 'ПРОПУЩЕНО: %s не обычный файл, не удаляю\n' "$IMAGE"
  fi
fi

rmdir "$MOUNT" 2>/dev/null || true

printf 'ПРОЙДЕНО: хранилище отключено. Данные на разделе, если он был, не тронуты.\n'
